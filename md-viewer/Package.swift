// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "md-viewer",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "MDViewerCore"),
    .target(
      name: "MDViewerWeb",
      dependencies: ["MDViewerCore"],
      resources: [.copy("Resources/web")]),
    .executableTarget(name: "md-viewer", dependencies: ["MDViewerCore", "MDViewerWeb"]),
    .executableTarget(name: "MDViewerHandler", dependencies: ["MDViewerCore"]),
    .testTarget(
      name: "MDViewerCoreTests",
      dependencies: ["MDViewerCore"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "MDViewerRenderTests",
      dependencies: ["MDViewerWeb"],
      resources: [.copy("Fixtures")]),
  ]
)
