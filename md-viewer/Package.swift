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
    .target(name: "MDViewerLayout", dependencies: ["MDViewerDocument"]),
    .target(
      name: "MDViewerRender",
      dependencies: ["MDViewerCore", "MDViewerDocument", "MDViewerLayout"],
      resources: [.copy("Resources/highlight.min.js"), .copy("Resources/THIRD_PARTY_NOTICES")]),
    .target(name: "MDViewerSystem"),
    .target(
      name: "MDViewerDisplay", dependencies: ["MDViewerCore", "MDViewerLayout", "MDViewerRender", "MDViewerSystem"]),
    .target(
      name: "MDViewerInteraction",
      dependencies: ["MDViewerCore", "MDViewerDocument", "MDViewerLayout", "MDViewerRender"]),
    .target(
      name: "MDViewerWeb",
      dependencies: ["MDViewerCore"],
      resources: [.copy("Resources/web")]),
    .target(
      name: "MDViewerMermaid",
      dependencies: ["MDViewerCore"],
      resources: [.copy("Resources/mermaid")]),
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
      name: "MDViewerLayoutTests",
      dependencies: ["MDViewerLayout", "MDViewerDocument"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "MDViewerRasterTests",
      dependencies: ["MDViewerRender", "MDViewerLayout", "MDViewerCore", "MDViewerDocument", "MDViewerMermaid"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "MDViewerDisplayTests",
      dependencies: ["MDViewerDisplay", "MDViewerRender", "MDViewerLayout", "MDViewerCore", "MDViewerSystem"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "MDViewerInteractionTests",
      dependencies: ["MDViewerInteraction", "MDViewerLayout", "MDViewerRender", "MDViewerCore", "MDViewerDocument"]),
    .testTarget(
      name: "MDViewerMermaidTests",
      dependencies: ["MDViewerMermaid", "MDViewerCore"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "MDViewerRenderTests",
      dependencies: ["MDViewerCore", "MDViewerWeb"],
      resources: [.copy("Fixtures")]),
  ]
)
