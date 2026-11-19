// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "sideclick",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "SideclickCore"),
    .executableTarget(name: "SideclickHandler", dependencies: ["SideclickCore"]),
    .executableTarget(name: "sideclick", dependencies: ["SideclickCore"]),
    .testTarget(
      name: "SideclickCoreTests",
      dependencies: ["SideclickCore"],
      resources: [.copy("Fixtures")]),
  ]
)
