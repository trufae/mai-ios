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
    .library(name: "MaiMCP", targets: ["MaiMCP"]),
    .library(name: "MaiVisionOCR", targets: ["MaiVisionOCR"]),
    .library(name: "MaiPluginSDK", targets: ["MaiPluginSDK"]),
    .library(name: "MaiPluginHost", targets: ["MaiPluginHost"]),
    .library(name: "MaiFixturePlugin", type: .dynamic, targets: ["MaiFixturePlugin"]),
    .executable(name: "pmai", targets: ["MaiCLI"]),
  ],
  targets: [
    .target(name: "MaiCore"),
    .target(name: "MaiOpenAI", dependencies: ["MaiCore"]),
    .target(name: "MaiMCP", dependencies: ["MaiCore"]),
    .target(name: "MaiVisionOCR", dependencies: ["MaiCore"]),
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
      dependencies: ["MaiCore", "MaiMCP", "MaiOpenAI", "MaiPluginHost", "MaiVisionOCR"],
      path: "Sources/mai"),
    .testTarget(
      name: "MaiCoreTests",
      dependencies: ["MaiCore", "MaiMCP", "MaiOpenAI", "MaiPluginHost", "MaiVisionOCR"]),
  ])
