// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "md-viewer",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-cmark", revision: "437611671145d47e6d9679761b8a5987766f4ae5")
  ],
  targets: [
    .target(name: "MDViewerCore"),
    .target(
      name: "MDViewerDocument",
      dependencies: [
        "MDViewerCore",
        .product(name: "cmark-gfm", package: "swift-cmark"),
        .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
      ]),
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
      name: "MDViewerDocumentTests",
      dependencies: ["MDViewerDocument"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "MDViewerRenderTests",
      dependencies: ["MDViewerCore", "MDViewerWeb"],
      resources: [.copy("Fixtures")]),
  ]
)
