// swift-tools-version: 6.0
import PackageDescription

// Host runtime products, diagnostic executables and Mac tests; Apple app targets are in project.yml.
let package = Package(
  name: "MunieHostTests",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "MunieProductHost", targets: ["MunieProductHost"]),
    .library(name: "MunieHostTransport", targets: ["MunieHostTransport"]),
    .executable(name: "MunieHostService", targets: ["MunieHostService"]),
    .executable(name: "MunieCodexGuardian", targets: ["MunieCodexGuardian"]),
  ],
  dependencies: [
    .package(path: "packages/MunieCore"),
    .package(path: "packages/MunieRemote"),
  ],
  targets: [
    .executableTarget(name: "MunieCodexGuardian", path: "apps/MunieHost/Guardian"),
    .target(
      name: "MunieProductHost",
      dependencies: ["MunieExecutionHost", .product(name: "MunieRemote", package: "MunieRemote")],
      path: "apps/MunieHost/Product"),
    .target(
      name: "MunieHostTransport",
      dependencies: [
        "MunieProductHost", "MunieExecutionHost",
        .product(name: "MunieRemote", package: "MunieRemote"),
      ],
      path: "apps/MunieHost/Transport"),
    .executableTarget(
      name: "MunieHostService",
      dependencies: [
        "MunieProductHost", "MunieHostTransport", "MunieExecutionHost",
        .product(name: "MunieRemote", package: "MunieRemote"),
      ],
      path: "apps/MunieHost/Service"),
    .testTarget(
      name: "MunieProductHostTests",
      dependencies: [
        "MunieProductHost", "MunieExecutionHost",
        .product(name: "MunieRemote", package: "MunieRemote"),
      ],
      path: "apps/MunieProductHostTests"),
    .testTarget(
      name: "MunieHostTransportTests",
      dependencies: [
        "MunieHostTransport", "MunieProductHost",
        .product(name: "MunieRemote", package: "MunieRemote"),
      ],
      path: "apps/MunieHostTransportTests"),
    .target(
      name: "MunieExecutionHost",
      path: "apps/MunieHost/Execution"),
    .executableTarget(
      name: "MunieSubmissionProbe", dependencies: ["MunieExecutionHost"],
      path: "apps/MunieHost/Probe"),
    .executableTarget(
      name: "MunieCodexHostProbe", dependencies: ["MunieExecutionHost"],
      path: "apps/MunieHost/CodexProbe"),
    .executableTarget(
      name: "MunieNativeNetworkProbe", dependencies: ["MunieExecutionHost"],
      path: "apps/MunieHost/NetworkProbe"),
    .executableTarget(
      name: "MunieLedgerNetworkProbe", dependencies: ["MunieExecutionHost"],
      path: "apps/MunieHost/LedgerNetworkProbe"),
    .testTarget(
      name: "MunieLedgerNetworkProbeTests",
      dependencies: ["MunieLedgerNetworkProbe", "MunieExecutionHost"],
      path: "apps/MunieLedgerNetworkProbeTests"),
    .testTarget(
      name: "MunieNativeNetworkProbeTests", dependencies: ["MunieNativeNetworkProbe"],
      path: "apps/MunieNetworkProbeTests"),
    .testTarget(
      name: "MunieExecutionHostTests", dependencies: ["MunieExecutionHost"],
      path: "apps/MunieHostTests"),
    .target(
      name: "Munie",
      dependencies: [.product(name: "MunieCore", package: "MunieCore")],
      path: "apps/Munie/Features/Capture",
      exclude: ["CaptureView.swift"],
      sources: ["CaptureModel.swift"]),
    .testTarget(
      name: "MuniePresentationTests", dependencies: ["Munie"], path: "apps/MunieTests"),
  ]
)
