import XCTest

@testable import MunieRemodex

@MainActor
final class MunieAppLaunchIsolationTests: XCTestCase {
  func testFixtureDoesNotConstructProductionStoresEvenWithHostedTestEnvironment() {
    for isHostedTest in [false, true] {
      let route = MunieAppLaunchRoute.resolve(
        arguments: ["Munie", "-CodexUITestsFixture"], isHostedTest: isHostedTest)
      var productionStoreValue = "pristine synthetic Keychain sentinel"
      var factoryCalls: [String] = []

      let root = route.makeRoot(
        production: {
          factoryCalls.append("production")
          productionStoreValue = "production store was initialized"
          return "production"
        },
        timelineFixture: {
          factoryCalls.append("fixture")
          return "fixture"
        },
        hostedTests: {
          factoryCalls.append("hosted")
          return "hosted"
        })

      XCTAssertEqual(root, "fixture")
      XCTAssertEqual(factoryCalls, ["fixture"])
      XCTAssertEqual(productionStoreValue, "pristine synthetic Keychain sentinel")
    }
  }

  func testHostedUnitTestsDoNotConstructProductionOrFixtureDependencies() {
    let route = MunieAppLaunchRoute.resolve(arguments: ["Munie"], isHostedTest: true)
    var factoryCalls: [String] = []
    let root = route.makeRoot(
      production: {
        factoryCalls.append("production")
        return "production"
      },
      timelineFixture: {
        factoryCalls.append("fixture")
        return "fixture"
      },
      hostedTests: {
        factoryCalls.append("hosted")
        return "hosted"
      })
    XCTAssertEqual(root, "hosted")
    XCTAssertEqual(factoryCalls, ["hosted"])
  }

  func testOrdinaryDebugLaunchUsesProductionDependencies() {
    let route = MunieAppLaunchRoute.resolve(arguments: ["Munie"], isHostedTest: false)
    var productionFactoryCalls = 0
    let root = route.makeRoot(
      production: {
        productionFactoryCalls += 1
        return "production"
      },
      timelineFixture: { "fixture" }, hostedTests: { "hosted" })
    XCTAssertEqual(root, "production")
    XCTAssertEqual(productionFactoryCalls, 1)
  }

  func testPartialFixtureArgumentCannotDisableProductionStartup() {
    XCTAssertEqual(
      MunieAppLaunchRoute.resolve(
        arguments: ["Munie", "-CodexUITestsFixtureExtra"], isHostedTest: false), .production)
  }
}
