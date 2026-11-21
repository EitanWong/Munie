// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MunieNearby",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [.library(name: "MunieNearby", targets: ["MunieNearby"])],
  targets: [
    .target(name: "MunieNearby"),
    .testTarget(name: "MunieNearbyTests", dependencies: ["MunieNearby"]),
  ]
)
