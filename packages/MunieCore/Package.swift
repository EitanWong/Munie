// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MunieCore",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "MunieCore", targets: ["MunieCore"]),
    .executable(name: "MunieCoreSmoke", targets: ["MunieCoreSmoke"]),
  ],
  targets: [
    .target(name: "MunieCore"),
    .executableTarget(name: "MunieCoreSmoke", dependencies: ["MunieCore"]),
    .testTarget(name: "MunieCoreTests", dependencies: ["MunieCore"]),
  ]
)
