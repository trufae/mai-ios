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
    .library(name: "MaiOpenAI", targets: ["MaiOpenAI"]),
    .library(name: "MaiPluginSDK", targets: ["MaiPluginSDK"]),
    .library(name: "MaiPluginHost", targets: ["MaiPluginHost"]),
    .library(name: "MaiFixturePlugin", type: .dynamic, targets: ["MaiFixturePlugin"]),
    .executable(name: "mai", targets: ["MaiCLI"]),
  ],
  targets: [
    .target(name: "MaiCore"),
    .target(name: "MaiOpenAI", dependencies: ["MaiCore"]),
    .target(
      name: "CMaiPluginABI",
      publicHeadersPath: "include"),
    .target(
      name: "MaiPluginSDK",
      dependencies: ["CMaiPluginABI"]),
    .target(
      name: "MaiPluginHost",
      dependencies: ["MaiCore", "MaiPluginSDK", "CMaiPluginABI"]),
    .target(
      name: "MaiFixturePlugin",
      dependencies: ["MaiPluginSDK", "CMaiPluginABI"]),
    .executableTarget(
      name: "MaiCLI",
      dependencies: ["MaiCore", "MaiOpenAI", "MaiPluginHost"],
      path: "Sources/mai"),
    .testTarget(
      name: "MaiCoreTests",
      dependencies: ["MaiCore", "MaiOpenAI", "MaiPluginHost"]),
  ])
