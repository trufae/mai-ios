// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "aitest",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "aitest",
      path: "Sources/aitest"
    )
  ]
)
