// swift-tools-version: 6.0
import PackageDescription

// Host-side test harness for presentation logic; the shipping app is defined in project.yml.
let package = Package(
  name: "MunieHostTests",
  platforms: [.macOS(.v15)],
  dependencies: [.package(path: "packages/MunieCore")],
  targets: [
    .target(
      name: "Munie",
      dependencies: [.product(name: "MunieCore", package: "MunieCore")],
      path: "apps/ios/Munie/Features/Capture",
      exclude: ["CaptureView.swift"],
      sources: ["CaptureModel.swift"]),
    .testTarget(
      name: "MuniePresentationTests", dependencies: ["Munie"], path: "apps/ios/MunieTests"),
  ]
)
