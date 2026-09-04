// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MaiCore",
  platforms: [
    .macOS(.v13),
    .iOS(.v18),
  ],
  products: [
    .library(name: "MaiCore", targets: ["MaiCore"]),
    .executable(name: "mai", targets: ["MaiCLI"]),
  ],
  targets: [
    .target(name: "MaiCore"),
    .executableTarget(
      name: "MaiCLI",
      dependencies: ["MaiCore"],
      path: "Sources/mai"),
    .testTarget(
      name: "MaiCoreTests",
      dependencies: ["MaiCore"]),
  ])
