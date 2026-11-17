import Foundation
import XCTest

@testable import MunieRemodex

@MainActor
final class CodexPersistenceIsolationTests: XCTestCase {
  func testProductionNamespaceIgnoresFixtureRunID() {
    XCTAssertEqual(
      SecureStore.resolvedStorageNamespace(
        appService: "fixture.app", isHostedTest: false, runID: UUID().uuidString),
      "fixture.app")
  }

  func testHostedNamespaceUsesOnlyCanonicalUUID() {
    let runID = "8E5C7A01-E348-4844-97BA-0F74D5C64415"
    XCTAssertEqual(
      SecureStore.resolvedStorageNamespace(
        appService: "fixture.app", isHostedTest: true, runID: runID),
      "fixture.app.test-fixture." + runID.lowercased())
    for invalid in [nil, "../production", "not-a-uuid"] {
      XCTAssertEqual(
        SecureStore.resolvedStorageNamespace(
          appService: "fixture.app", isHostedTest: true, runID: invalid),
        "fixture.app.test-fixture")
    }
  }

  func testProductionPreferencesKeepStandardDependency() throws {
    let suiteName = "CodexPersistenceIsolationTests.production." + UUID().uuidString
    let production = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { production.removePersistentDomain(forName: suiteName) }
    XCTAssertTrue(
      SecureStore.resolvedUserDefaults(
        appService: suiteName, storageNamespace: suiteName,
        productionDefaults: production) === production)
  }

  func testHostedPreferenceWritesAndRemovalsPreserveProductionSentinels() async throws {
    let appService = "CodexPersistenceIsolationTests.production." + UUID().uuidString
    let production = try XCTUnwrap(UserDefaults(suiteName: appService))
    let namespace = SecureStore.resolvedStorageNamespace(
      appService: appService, isHostedTest: true, runID: UUID().uuidString)
    let fixture = SecureStore.resolvedUserDefaults(
      appService: appService, storageNamespace: namespace,
      productionDefaults: production)
    defer {
      production.removePersistentDomain(forName: appService)
      fixture.removePersistentDomain(forName: namespace)
    }
    production.set("production-model-sentinel", forKey: CodexService.selectedModelIdDefaultsKey)
    production.set(
      "production-effort-sentinel", forKey: CodexService.selectedReasoningEffortDefaultsKey)
    production.set("production-access-sentinel", forKey: CodexService.selectedAccessModeDefaultsKey)
    let sentinels = production.persistentDomain(forName: appService) as NSDictionary?

    let service = CodexService(defaults: fixture)
    XCTAssertNil(service.selectedModelId)
    service.setSelectedModelId("fixture-model")
    service.setSelectedAccessMode(.onRequest)
    XCTAssertEqual(fixture.string(forKey: CodexService.selectedModelIdDefaultsKey), "fixture-model")
    service.setSelectedModelId(nil)
    XCTAssertNil(fixture.object(forKey: CodexService.selectedModelIdDefaultsKey))
    XCTAssertEqual(production.persistentDomain(forName: appService) as NSDictionary?, sentinels)
    await MunieTestServiceLifecycle.finish([service])
  }

  func testDefaultServiceUsesTheHostedPreferenceNamespace() async throws {
    let service = CodexService()
    let namespace = SecureStore.storageNamespace
    let fixture = try XCTUnwrap(UserDefaults(suiteName: namespace))
    let sentinelID = UUID().uuidString
    let key = "isolation-sentinel-" + sentinelID
    defer { service.defaults.removeObject(forKey: key) }
    let productionValue = UserDefaults.standard.object(forKey: key)
    XCTAssertFalse(service.defaults === UserDefaults.standard)
    service.defaults.set(sentinelID, forKey: key)
    XCTAssertEqual(fixture.string(forKey: key), sentinelID)
    XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? String, productionValue as? String)
    await MunieTestServiceLifecycle.finish([service])
  }

  func testAllPersistenceWritesRoundTripInsideHostedNamespace() throws {
    let bundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
    XCTAssertTrue(SecureStore.storageNamespace.hasPrefix(bundleID + ".test-fixture"))
    let fileManager = FileManager.default
    let base = try XCTUnwrap(
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
    let fixtureID = "storage-isolation-" + UUID().uuidString.lowercased()
    let relativeDirectory = "mac/" + fixtureID
    let fixtureDirectory = base.appendingPathComponent(SecureStore.storageNamespace)
      .appendingPathComponent(relativeDirectory)
    let productionDirectory = base.appendingPathComponent(bundleID)
      .appendingPathComponent(relativeDirectory)
    XCTAssertFalse(fileManager.fileExists(atPath: productionDirectory.path))
    defer { try? fileManager.removeItem(at: fixtureDirectory) }

    let threadID = UUID().uuidString
    let messages = CodexMessagePersistence()
    messages.save(
      [threadID: [CodexMessage(threadId: threadID, role: .assistant, text: "fixture")]],
      macDeviceId: fixtureID)
    XCTAssertEqual(messages.load(macDeviceId: fixtureID)[threadID]?.first?.text, "fixture")

    let drafts = CodexComposerDraftPersistence()
    let draft = TurnComposerLocalDraft(
      input: "fixture draft", mentionedFiles: [], mentionedSkills: [], mentionedPlugins: [],
      attachments: [], reviewSelection: nil, isPlanModeArmed: false,
      isSubagentsSelectionArmed: false, updatedAt: Date())
    drafts.save([threadID: draft], macDeviceId: fixtureID)
    XCTAssertEqual(drafts.load(macDeviceId: fixtureID)[threadID]?.input, "fixture draft")

    let threads = CodexThreadListPersistence()
    threads.save([CodexThread(id: threadID)], macDeviceId: fixtureID)
    XCTAssertEqual(threads.load(macDeviceId: fixtureID).map(\.id), [threadID])

    let changeSets = AIChangeSetPersistence()
    XCTAssertTrue(changeSets.save([], macDeviceId: fixtureID))
    XCTAssertEqual(changeSets.load(macDeviceId: fixtureID)?.count, 0)

    for name in [
      "codex-message-history-v6.bin", "codex-composer-drafts-v1.bin",
      "codex-thread-list-v1.bin", "codex-ai-change-sets-v1.json",
    ] {
      XCTAssertTrue(
        fileManager.fileExists(atPath: fixtureDirectory.appendingPathComponent(name).path))
    }
    XCTAssertFalse(fileManager.fileExists(atPath: productionDirectory.path))
  }
}
