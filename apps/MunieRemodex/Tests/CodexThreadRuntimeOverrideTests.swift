// Munie modification: catalog/native defaults, explicit runtime choices and current protocol fixtures.
// FILE: CodexThreadRuntimeOverrideTests.swift
// Purpose: Verifies per-thread runtime overrides for reasoning and speed beat app defaults.
// Layer: Unit Test
// Exports: CodexThreadRuntimeOverrideTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import MunieRemodex

@MainActor
final class CodexThreadRuntimeOverrideTests: XCTestCase {
    // Swift 6.2 compatibility: avoid inferred isolated teardown (Swift #85663).
    nonisolated deinit {}

    private static var retainedServices: [CodexService] = []

    override func tearDown() async throws {
        await MunieTestServiceLifecycle.finish(Self.retainedServices)
        Self.retainedServices.removeAll()
        try await super.tearDown()
    }

    func testTurnStartUsesThreadRuntimeOverridesInsteadOfAppDefaults() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.setSelectedReasoningEffort("medium")
        service.setSelectedServiceTier(.fast)
        service.setThreadReasoningEffortOverride("high", for: "thread-override")
        service.setThreadServiceTierOverride(nil, for: "thread-override")

        var capturedTurnStartParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            if method == "workspace/checkpointCapture" || method == "workspace/checkpointCopy" {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
            XCTAssertEqual(method, "turn/start")
            capturedTurnStartParams.append(params ?? .null)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-override")]),
                includeJSONRPC: false
            )
        }

        try await service.sendTurnStart("Ship it", to: "thread-override")

        XCTAssertEqual(capturedTurnStartParams.count, 1)
        XCTAssertEqual(capturedTurnStartParams[0].objectValue?["effort"]?.stringValue, "high")
        XCTAssertEqual(capturedTurnStartParams[0].objectValue?["serviceTier"]?.stringValue, "default")
    }

    func testThreadServiceTierOverridePersistsExplicitNormalSelection() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let firstService = CodexService(defaults: defaults)
        Self.retainedServices.append(firstService)
        firstService.setSelectedServiceTier(.fast)
        firstService.setThreadServiceTierOverride(nil, for: "thread-normal")

        XCTAssertTrue(firstService.isThreadServiceTierOverridden("thread-normal"))
        XCTAssertNil(firstService.effectiveServiceTier(for: "thread-normal"))

        let secondService = CodexService(defaults: defaults)
        Self.retainedServices.append(secondService)

        XCTAssertTrue(secondService.isThreadServiceTierOverridden("thread-normal"))
        XCTAssertNil(secondService.effectiveServiceTier(for: "thread-normal"))
    }

    func testPhoneRuntimeSettingsBecomeThreadScopedWithoutChangingAppDefaults() {
        let service = makeService()
        service.availableModels = [makeModel(), makeGPT55Model()]
        service.setSelectedModelId("gpt-5.4")
        service.setSelectedReasoningEffort("medium")
        service.setSelectedServiceTier(nil)

        service.applyRemoteRuntimeSettings(from: CodexThread(
            id: "thread-remote",
            model: "gpt-5.5",
            reasoningEffort: "high",
            serviceTier: "fast",
            runtimeSettingsRevision: 1,
            runtimeSettingsUpdatedAt: 123,
            runtimeSettingsSource: "phone"
        ))

        XCTAssertEqual(service.selectedModelId, "gpt-5.4")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.4")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(threadId: "thread-remote"), "gpt-5.5")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(threadId: "thread-remote"), "high")
        XCTAssertEqual(service.effectiveServiceTier(for: "thread-remote"), .fast)

        service.applyRemoteRuntimeSettings(from: CodexThread(
            id: "thread-remote",
            model: "gpt-5.4",
            reasoningEffort: "medium",
            serviceTier: nil,
            runtimeSettingsRevision: 2,
            runtimeSettingsUpdatedAt: 456,
            runtimeSettingsSource: "phone"
        ))

        XCTAssertEqual(service.runtimeModelIdentifierForTurn(threadId: "thread-remote"), "gpt-5.4")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(threadId: "thread-remote"), "medium")
        XCTAssertNil(service.effectiveServiceTier(for: "thread-remote"))
    }

    func testNewerTimestampWinsAfterBridgeRevisionResets() {
        let service = makeService()
        service.availableModels = [makeModel(), makeGPT55Model()]

        service.applyRemoteRuntimeSettings(from: CodexThread(
            id: "thread-reset",
            model: "gpt-5.5",
            reasoningEffort: "high",
            serviceTier: "fast",
            runtimeSettingsRevision: 12,
            runtimeSettingsUpdatedAt: 100,
            runtimeSettingsSource: "phone"
        ))
        service.applyRemoteRuntimeSettings(from: CodexThread(
            id: "thread-reset",
            model: "gpt-5.4",
            reasoningEffort: "medium",
            serviceTier: nil,
            runtimeSettingsRevision: 1,
            runtimeSettingsUpdatedAt: 200,
            runtimeSettingsSource: "phone"
        ))

        XCTAssertEqual(service.runtimeModelIdentifierForTurn(threadId: "thread-reset"), "gpt-5.4")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(threadId: "thread-reset"), "medium")
        XCTAssertNil(service.effectiveServiceTier(for: "thread-reset"))
        XCTAssertEqual(service.threadRuntimeOverride(for: "thread-reset")?.runtimeSettingsRevision, 1)
    }

    func testDesktopRuntimeSettingsDoNotOverridePhoneSelection() {
        let service = makeService()
        service.availableModels = [makeModel(), makeGPT55Model()]
        service.setThreadModelOverride("gpt-5.4", for: "thread-phone-authority")
        service.setThreadReasoningEffortOverride("medium", for: "thread-phone-authority")

        service.applyRemoteRuntimeSettings(from: CodexThread(
            id: "thread-phone-authority",
            model: "gpt-5.5",
            reasoningEffort: "high",
            serviceTier: "fast",
            runtimeSettingsRevision: 9,
            runtimeSettingsUpdatedAt: 999,
            runtimeSettingsSource: "desktop"
        ))

        XCTAssertEqual(service.runtimeModelIdentifierForTurn(threadId: "thread-phone-authority"), "gpt-5.4")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(threadId: "thread-phone-authority"), "medium")
        XCTAssertNil(service.effectiveServiceTier(for: "thread-phone-authority"))
    }

    func testClearingSelectedModelUsesCatalogDefaultAndReasoning() {
        let service = makeService()
        service.availableModels = [makeGPT55Model(), makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.setSelectedReasoningEffort("high")

        service.setSelectedModelId(nil)

        XCTAssertNil(service.selectedModelId)
        XCTAssertNil(service.selectedReasoningEffort)
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.4")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(), "medium")
    }

    func testPersistedModelSelectionIsUsableBeforeModelListRefresh() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("gpt-5.3-codex", forKey: CodexService.selectedModelIdDefaultsKey)

        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)

        XCTAssertTrue(service.availableModels.isEmpty)
        XCTAssertTrue(service.hasPersistedSelectedModelId)
        XCTAssertEqual(service.selectedModelId, "gpt-5.3-codex")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.3-codex")
        XCTAssertNil(service.selectedReasoningEffortForSelectedModel())
        XCTAssertEqual(
            TurnComposerMetaMapper.modelTitle(forIdentifier: service.selectedModelId),
            "GPT-5.3-Codex"
        )
    }

    func testComposerKeepsExplicitGPT55VisibleBeforeModelListRefresh() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("gpt-5.5", forKey: CodexService.selectedModelIdDefaultsKey)

        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        service.isBootstrappingConnectionSync = true

        XCTAssertTrue(service.availableModels.isEmpty)
        XCTAssertEqual(service.visibleSelectedModelIDForComposer(), "gpt-5.5")
        XCTAssertFalse(service.isRuntimeSelectionLoadingForComposer())
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.5")
    }

    func testComposerKeepsCustomPersistedModelVisibleDuringBootstrap() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("gpt-5.3-codex", forKey: CodexService.selectedModelIdDefaultsKey)

        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        service.isBootstrappingConnectionSync = true

        XCTAssertEqual(service.visibleSelectedModelIDForComposer(), "gpt-5.3-codex")
        XCTAssertFalse(service.isRuntimeSelectionLoadingForComposer())
    }

    func testDefaultModelFallbackIsNotPersistedBeforeModelListRefresh() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        service.normalizeRuntimeSelectionsAfterModelsUpdate()

        XCTAssertFalse(service.hasPersistedSelectedModelId)
        XCTAssertNil(service.selectedModelId)
        XCTAssertNil(service.selectedReasoningEffort)
        XCTAssertNil(service.runtimeModelIdentifierForTurn())
        XCTAssertNil(defaults.string(forKey: CodexService.selectedModelIdDefaultsKey))
    }

    func testModelListRefreshDoesNotPersistAutomaticDefaultAcrossHosts() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let firstService = CodexService(defaults: defaults)
        Self.retainedServices.append(firstService)
        firstService.availableModels = [makeGPT55Model(), makeModel()]
        firstService.normalizeRuntimeSelectionsAfterModelsUpdate()

        XCTAssertFalse(firstService.hasPersistedSelectedModelId)
        XCTAssertNil(firstService.selectedModelId)
        XCTAssertEqual(firstService.runtimeModelIdentifierForTurn(), "gpt-5.4")
        XCTAssertNil(defaults.string(forKey: CodexService.selectedModelIdDefaultsKey))

        let secondService = CodexService(defaults: defaults)
        Self.retainedServices.append(secondService)

        XCTAssertFalse(secondService.hasPersistedSelectedModelId)
        XCTAssertNil(secondService.selectedModelId)
        XCTAssertNil(secondService.runtimeModelIdentifierForTurn())
    }

    func testTurnPayloadOmitsModelAndEffortUntilCatalogLoads() throws {
        let service = makeService()
        let params = try service.buildTurnStartRequestParams(
            threadId: "native-default", userInput: "Ship it", attachments: [],
            skillMentions: [], mentionMentions: [], imageURLKey: "url",
            includeStructuredSkillItems: true, includeStructuredMentionItems: true,
            collaborationMode: nil, includeServiceTier: true
        )

        XCTAssertNil(params["model"])
        XCTAssertNil(params["effort"])
        XCTAssertEqual(params["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "Ship it")
    }

    func testClearingSelectionWithoutCatalogRestoresNativeDefault() {
        let service = makeService()
        service.setSelectedModelId("explicit-model")
        service.setSelectedReasoningEffort("high")

        service.setSelectedModelId(nil)

        XCTAssertNil(service.runtimeModelIdentifierForTurn())
        XCTAssertNil(service.selectedReasoningEffortForSelectedModel())
        XCTAssertFalse(service.hasPersistedSelectedModelId)
        XCTAssertNil(service.defaults.string(forKey: CodexService.selectedModelIdDefaultsKey))
    }

    func testAutomaticSelectionFollowsRefreshedCatalogDefault() {
        let service = makeService()
        service.availableModels = [makeGPT55Model(isDefault: true)]
        service.normalizeRuntimeSelectionsAfterModelsUpdate()
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.5")

        service.availableModels = [makeGPT55Model(), makeLowOnlyModel()]
        service.normalizeRuntimeSelectionsAfterModelsUpdate()

        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.4-low")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(), "low")
        XCTAssertNil(service.selectedReasoningEffort)
        XCTAssertNil(service.defaults.string(forKey: CodexService.selectedModelIdDefaultsKey))
    }

    func testCatalogRefreshPreservesExplicitModelMissingFromCatalog() {
        let service = makeService()
        service.setSelectedModelId("explicit-model")
        service.setSelectedReasoningEffort("high")
        service.availableModels = [makeModel(), makeGPT55Model()]
        service.normalizeRuntimeSelectionsAfterModelsUpdate()

        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "explicit-model")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(), "high")
        XCTAssertEqual(service.visibleSelectedModelIDForComposer(), "explicit-model")
        XCTAssertEqual(service.defaults.string(forKey: CodexService.selectedModelIdDefaultsKey), "explicit-model")
    }

    func testExplicitReasoningWithAutomaticModelRestoresAfterRelaunch() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let firstService = CodexService(defaults: defaults)
        Self.retainedServices.append(firstService)
        firstService.availableModels = [makeModel()]
        firstService.setSelectedReasoningEffort("high")

        XCTAssertNil(firstService.selectedModelId)
        XCTAssertEqual(firstService.selectedReasoningEffortForSelectedModel(), "high")
        XCTAssertEqual(defaults.string(forKey: CodexService.selectedReasoningEffortDefaultsKey), "high")

        let secondService = CodexService(defaults: defaults)
        Self.retainedServices.append(secondService)
        XCTAssertEqual(secondService.selectedReasoningEffort, "high")
        XCTAssertNil(secondService.runtimeModelIdentifierForTurn())
        XCTAssertNil(secondService.selectedReasoningEffortForSelectedModel())

        secondService.availableModels = [makeModel()]
        secondService.normalizeRuntimeSelectionsAfterModelsUpdate()
        XCTAssertEqual(secondService.runtimeModelIdentifierForTurn(), "gpt-5.4")
        XCTAssertEqual(secondService.selectedReasoningEffortForSelectedModel(), "high")

        secondService.availableModels = [makeLowOnlyModel()]
        secondService.normalizeRuntimeSelectionsAfterModelsUpdate()
        XCTAssertNil(secondService.selectedReasoningEffort)
        XCTAssertEqual(secondService.selectedReasoningEffortForSelectedModel(), "low")
    }

    func testThreadModelOverrideIsPreservedBeforeAndAfterCatalogLoads() {
        let service = makeService()
        service.setThreadModelOverride("thread-explicit-model", for: "thread-explicit")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(threadId: "thread-explicit"), "thread-explicit-model")

        service.availableModels = [makeModel(), makeGPT55Model()]
        service.normalizeRuntimeSelectionsAfterModelsUpdate()

        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.4")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(threadId: "thread-explicit"), "thread-explicit-model")
        XCTAssertNil(service.selectedModelId)
    }

    func testCatalogModelAliasResolvesToRuntimeModelIdentifier() {
        let service = makeService()
        service.availableModels = [CodexModelOption(
            id: "catalog-alias", model: "runtime-model", displayName: "Model", description: "",
            isDefault: true, supportedReasoningEfforts: [], defaultReasoningEffort: nil
        )]
        service.setSelectedModelId("runtime-model")

        XCTAssertEqual(service.selectedModelId, "catalog-alias")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "runtime-model")
    }

    func testContinuationInheritsThreadRuntimeOverrides() {
        let service = makeService()
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.applyThreadRuntimeOverride(CodexThreadRuntimeOverride(
            modelId: "gpt-5.4",
            reasoningEffort: "high",
            serviceTierRawValue: CodexServiceTier.fast.rawValue,
            overridesModel: true,
            overridesReasoning: true,
            overridesServiceTier: true,
            runtimeSettingsRevision: 9,
            runtimeSettingsUpdatedAt: 123
        ), to: "thread-old")

        service.inheritThreadRuntimeOverrides(from: "thread-old", to: "thread-new")

        XCTAssertEqual(
            service.selectedReasoningEffortForSelectedModel(threadId: "thread-new"),
            "high"
        )
        XCTAssertEqual(service.effectiveServiceTier(for: "thread-new"), .fast)
        XCTAssertEqual(service.threadRuntimeOverride(for: "thread-new")?.runtimeSettingsRevision, 0)
        XCTAssertEqual(service.threadRuntimeOverride(for: "thread-new")?.runtimeSettingsUpdatedAt, 0)
    }

    func testStartThreadUsesProvidedRuntimeOverrideForServiceTier() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.setSelectedServiceTier(nil)

        var capturedThreadStartParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/start")
            capturedThreadStartParams.append(params ?? .null)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string("thread-new"),
                        "cwd": .string("/tmp/project"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let override = CodexThreadRuntimeOverride(
            reasoningEffort: "high",
            serviceTierRawValue: "fast",
            overridesReasoning: true,
            overridesServiceTier: true
        )
        let thread = try await service.startThread(runtimeOverride: override)

        XCTAssertEqual(thread.id, "thread-new")
        XCTAssertEqual(capturedThreadStartParams.first?.objectValue?["serviceTier"]?.stringValue, "priority")
        XCTAssertEqual(service.effectiveServiceTier(for: "thread-new"), .fast)
        XCTAssertTrue(service.hydratedThreadIDs.contains("thread-new"))
        XCTAssertTrue(service.initialTurnsLoadedByThreadID.contains("thread-new"))
    }

    func testStartThreadDropsFastRuntimeOverrideWhenSelectedModelDoesNotSupportFastMode() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeLowOnlyModel()]
        service.setSelectedModelId("gpt-5.4-low")

        var capturedThreadStartParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/start")
            capturedThreadStartParams.append(params ?? .null)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string("thread-new"),
                        "cwd": .string("/tmp/project"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let override = CodexThreadRuntimeOverride(
            reasoningEffort: "low",
            serviceTierRawValue: "fast",
            overridesReasoning: true,
            overridesServiceTier: true
        )
        _ = try await service.startThread(runtimeOverride: override)

        XCTAssertEqual(capturedThreadStartParams.first?.objectValue?["serviceTier"]?.stringValue, "default")
    }

    func testUnsupportedThreadReasoningOverrideIsNotReportedAsActive() {
        let service = makeService()
        service.availableModels = [makeLowOnlyModel()]
        service.setSelectedModelId("gpt-5.4-low")
        service.setThreadReasoningEffortOverride("high", for: "thread-old")

        XCTAssertFalse(service.isThreadReasoningEffortOverridden("thread-old"))
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(threadId: "thread-old"), "low")
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.isInitialized = true // Synthetic transport peer has completed initialize.
        Self.retainedServices.append(service)
        return service
    }

    private func makeModel() -> CodexModelOption {
        CodexModelOption(
            id: "gpt-5.4",
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            description: "Test model",
            isDefault: true,
            supportsFastMode: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: "Medium"),
                CodexReasoningEffortOption(reasoningEffort: "high", description: "High"),
            ],
            defaultReasoningEffort: "medium"
        )
    }

    private func makeGPT55Model(isDefault: Bool = false) -> CodexModelOption {
        CodexModelOption(
            id: "gpt-5.5",
            model: "gpt-5.5",
            displayName: "GPT-5.5",
            description: "Test model",
            isDefault: isDefault,
            supportsFastMode: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: "Medium"),
                CodexReasoningEffortOption(reasoningEffort: "high", description: "High"),
            ],
            defaultReasoningEffort: "medium"
        )
    }

    private func makeLowOnlyModel() -> CodexModelOption {
        CodexModelOption(
            id: "gpt-5.4-low",
            model: "gpt-5.4-low",
            displayName: "GPT-5.4 Low",
            description: "Test model",
            isDefault: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "low", description: "Low"),
            ],
            defaultReasoningEffort: "low"
        )
    }
}
