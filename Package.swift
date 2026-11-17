// swift-tools-version: 6.0
import PackageDescription

// Host-side presentation tests and execution research; shipping apps remain in project.yml.
let package = Package(
  name: "MunieHostTests",
  platforms: [.macOS(.v15)],
  dependencies: [.package(path: "packages/MunieCore")],
  targets: [
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
