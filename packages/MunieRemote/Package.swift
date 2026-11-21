// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MunieRemote",
  platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11), .tvOS(.v18), .visionOS(.v2)],
  products: [.library(name: "MunieRemote", targets: ["MunieRemote"])],
  targets: [
    .target(name: "MunieRemote"),
    .testTarget(name: "MunieRemoteTests", dependencies: ["MunieRemote"]),
  ]
)
