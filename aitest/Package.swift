// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "aitest",
  platforms: [.macOS(.v13)],
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
