// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MaiCore",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
  ],
  products: [
    .library(name: "MaiCore", targets: ["MaiCore"]),
    .library(name: "MaiOpenAI", targets: ["MaiOpenAI"]),
    .library(name: "MaiMCP", targets: ["MaiMCP"]),
    .library(name: "MaiStandardTools", targets: ["MaiStandardTools"]),
    .library(name: "MaiVisionOCR", targets: ["MaiVisionOCR"]),
    .library(name: "MaiPluginSDK", targets: ["MaiPluginSDK"]),
    .library(name: "MaiPluginHost", targets: ["MaiPluginHost"]),
    .library(name: "MaiVisual", targets: ["MaiVisual"]),
    .library(name: "MaiDocuments", targets: ["MaiDocuments"]),
    .library(name: "MaiFixturePlugin", type: .dynamic, targets: ["MaiFixturePlugin"]),
    .executable(name: "pmai", targets: ["MaiCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/SwiftTUI/swift-tui", .upToNextMinor(from: "0.10.1"))
  ],
  targets: [
    .target(name: "MaiCore"),
    .target(name: "MaiOpenAI", dependencies: ["MaiCore"]),
    .target(name: "MaiMCP", dependencies: ["MaiCore"]),
    .target(name: "MaiStandardTools", dependencies: ["MaiCore"]),
    .target(name: "MaiVisionOCR", dependencies: ["MaiCore"]),
    .target(name: "MaiDocuments", dependencies: ["MaiCore"]),
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
    .target(
      name: "MaiVisual",
      dependencies: [
        "MaiCore",
        .product(name: "SwiftTUIRuntime", package: "swift-tui"),
        .product(name: "SwiftTUICLI", package: "swift-tui"),
      ]),
    .executableTarget(
      name: "MaiCLI",
      dependencies: [
        "MaiCore", "MaiMCP", "MaiOpenAI", "MaiPluginHost", "MaiStandardTools", "MaiVisionOCR",
        "MaiVisual", "MaiDocuments",
      ],
      path: "Sources/mai"),
    .testTarget(
      name: "MaiCoreTests",
      dependencies: [
        "MaiCore", "MaiMCP", "MaiOpenAI", "MaiPluginHost", "MaiStandardTools", "MaiVisionOCR",
        "MaiVisual", "MaiDocuments",
        .product(name: "SwiftTUIRuntime", package: "swift-tui"),
        .product(name: "SwiftTUICLI", package: "swift-tui"),
      ]),
  ])
