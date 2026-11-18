import XCTest

@testable import MunieRemodex

@MainActor
final class MunieAppLaunchIsolationTests: XCTestCase {
  // Swift 6.2 compatibility: avoid inferred isolated teardown (Swift #85663).
  nonisolated deinit {}

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

  func testOnboardingFixtureOnlyConstructsItsRootIncludingHostedLaunches() {
    for isHostedTest in [false, true] {
      let route = MunieAppLaunchRoute.resolve(
        arguments: ["Munie", "-CodexUITestsOnboardingFixture"], isHostedTest: isHostedTest)
      var factoryCalls: [String] = []
      let root = route.makeRoot(
        production: {
          XCTFail(
            "An onboarding fixture must not construct production stores or Keychain dependencies")
          factoryCalls.append("production")
          return "production"
        },
        timelineFixture: {
          factoryCalls.append("timeline")
          return "timeline"
        },
        hostedTests: {
          factoryCalls.append("hosted")
          return "hosted"
        },
        onboardingFixture: {
          factoryCalls.append("onboarding")
          return "onboarding"
        })
      XCTAssertEqual(route, .onboardingFixture)
      XCTAssertEqual(root, "onboarding")
      XCTAssertEqual(factoryCalls, ["onboarding"])
    }
  }

  func testOnboardingFixtureWithoutFactoryFailsClosedToHostedRoot() {
    let route = MunieAppLaunchRoute.resolve(
      arguments: ["Munie", "-CodexUITestsOnboardingFixture"], isHostedTest: false)
    var factoryCalls: [String] = []
    let root = route.makeRoot(
      production: {
        XCTFail("A missing fixture factory must not initialize production dependencies")
        factoryCalls.append("production")
        return "production"
      },
      timelineFixture: {
        factoryCalls.append("timeline")
        return "timeline"
      },
      hostedTests: {
        factoryCalls.append("hosted")
        return "hosted"
      })
    XCTAssertEqual(root, "hosted")
    XCTAssertEqual(factoryCalls, ["hosted"])
  }

  func testOnboardingFixtureUsesExactFlagAndWinsOverTimelineFlag() {
    for isHostedTest in [false, true] {
      XCTAssertEqual(
        MunieAppLaunchRoute.resolve(
          arguments: ["Munie", "-CodexUITestsOnboardingFixtureExtra"], isHostedTest: isHostedTest),
        isHostedTest ? .hostedTests : .production)
      XCTAssertEqual(
        MunieAppLaunchRoute.resolve(
          arguments: ["Munie", "-CodexUITestsFixture", "-CodexUITestsOnboardingFixture"],
          isHostedTest: isHostedTest), .onboardingFixture)
    }
  }
}
