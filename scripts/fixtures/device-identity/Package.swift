// swift-tools-version: 6.1
import PackageDescription

// Opt-in identity research only; not a dependency of any shipping app or the root package.
let package = Package(
  name: "MunieDeviceIdentityResearch",
  platforms: [.macOS(.v15)],
  products: [.executable(name: "MunieDeviceIdentityProbe", targets: ["MunieDeviceIdentityProbe"])],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-certificates.git",
      revision: "8789d7e78f996d56272836c8bf3590c5bd9c9754"),
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.1.1"),
    .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.4"),
  ],
  targets: [
    .executableTarget(
      name: "MunieDeviceIdentityProbe",
      dependencies: [
        .product(name: "X509", package: "swift-certificates"),
        .product(name: "SwiftASN1", package: "swift-asn1"),
        .product(name: "Crypto", package: "swift-crypto"),
      ]),
    .testTarget(name: "IdentityLifecycleTests", dependencies: ["MunieDeviceIdentityProbe"]),
  ],
  swiftLanguageModes: [.v6]
)
