// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "aitest",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(path: "../MaiCore")
  ],
  targets: [
    .executableTarget(
      name: "aitest",
      dependencies: [
        .product(name: "MaiCore", package: "MaiCore")
      ],
      path: "Sources/aitest"
    )
  ]
)
