import CoreGraphics
import Foundation
import MDViewerCore
import XCTest

@testable import MDViewerMermaid

@MainActor
final class MermaidRendererTests: XCTestCase {
  private let darkTheme = MermaidTheme(palette: .fallback(dark: true))
  private let lightTheme = MermaidTheme(palette: .fallback(dark: false))

  private func color(_ theme: MermaidTheme, _ name: String) throws -> RGB {
    let hex = try XCTUnwrap(theme.variables[name])
    return RGB(hex: try XCTUnwrap(UInt32(hex.dropFirst(), radix: 16)))
  }

  func testLocatesPageInBundle() throws {
    let page = try XCTUnwrap(MermaidRenderer.locatePage())
    XCTAssertEqual(page.lastPathComponent, "mermaid.html")
    XCTAssertNil(MermaidRenderer.locatePage(candidates: [URL(fileURLWithPath: "/nonexistent/x.bundle")]))
  }

  func testSampleFlowchartRendersInThemeColors() async throws {
    for theme in [darkTheme, lightTheme] {
      let renderer = MermaidRenderer()
      let request = MermaidRequest(code: try sampleFlowchart(), theme: theme, width: 760, scale: 2)
      let recording = RenderRecording()
      let diagram = await render(renderer, request, recording: recording)

      XCTAssertNil(diagram.failure)
      XCTAssertEqual(recording.recordedEvents, ["size", "image"])
      XCTAssertEqual(recording.recordedSizes, [diagram.size])
      XCTAssertGreaterThan(diagram.size.width, 300)
      XCTAssertLessThanOrEqual(diagram.size.width, 760)
      XCTAssertGreaterThan(diagram.size.height, 30)
      XCTAssertLessThan(diagram.size.height, 300)
      XCTAssertEqual(diagram.image.width, Int((diagram.size.width * 2).rounded(.down)))
      XCTAssertEqual(diagram.image.height, Int((diagram.size.height * 2).rounded(.down)))

      let pixels = PixelBuffer(diagram.image)
      let total = pixels.width * pixels.height
      XCTAssertLessThanOrEqual(pixels.distance(0, 0, to: theme.background), 3)
      XCTAssertLessThanOrEqual(pixels.distance(pixels.width - 1, pixels.height - 1, to: theme.background), 3)
      XCTAssertGreaterThan(pixels.count(near: try color(theme, "primaryColor")), total / 20, "node fill")
      XCTAssertGreaterThan(pixels.count(near: try color(theme, "primaryBorderColor"), tolerance: 12), 200, "border")
      XCTAssertGreaterThan(pixels.count(near: try color(theme, "lineColor"), tolerance: 12), 100, "edges")
      XCTAssertGreaterThan(pixels.count(near: theme.text, tolerance: 12), 100, "labels")
    }
  }

  func testSyntaxErrorProducesErrorImage() async throws {
    let renderer = MermaidRenderer()
    let request = MermaidRequest(code: "flowchart LR\n  A -->", theme: lightTheme, width: 600, scale: 2)
    let recording = RenderRecording()
    let diagram = await render(renderer, request, recording: recording)

    guard case .syntax(let message) = diagram.failure else { return XCTFail("\(String(describing: diagram.failure))") }
    XCTAssertFalse(message.isEmpty)
    XCTAssertEqual(recording.recordedEvents, ["size", "image"])
    XCTAssertEqual(diagram.size.width, 600)
    XCTAssertGreaterThan(diagram.size.height, 50)
    let pixels = PixelBuffer(diagram.image)
    let fill = lightTheme.background.mixed(with: lightTheme.errorAccent, 0.1)
    XCTAssertLessThanOrEqual(pixels.distance(pixels.width / 2, pixels.height - 8, to: fill), 3)
    let border = lightTheme.background.mixed(with: lightTheme.errorAccent, 0.6)
    XCTAssertLessThanOrEqual(pixels.distance(pixels.width / 2, 1, to: border), 24)
    XCTAssertGreaterThan(pixels.count(near: lightTheme.text, tolerance: 12), 100)
    XCTAssertNotNil(renderer.cached(request), "syntax errors are cached")

    let next = await render(
      renderer, MermaidRequest(code: "flowchart LR\n  A --> B", theme: lightTheme, width: 600, scale: 2))
    XCTAssertNil(next.failure, "the page keeps working after an error")
  }

  func testCacheHitSkipsTheEngine() async throws {
    let renderer = MermaidRenderer()
    let request = MermaidRequest(code: try sampleFlowchart(), theme: darkTheme, width: 760, scale: 2)
    XCTAssertNil(renderer.cached(request))
    let first = await render(renderer, request)
    XCTAssertEqual(renderer.engine.startCount, 1)
    let cached = try XCTUnwrap(renderer.cached(request))
    XCTAssertTrue(cached.image === first.image)
    XCTAssertEqual(renderer.sizeProvider(theme: darkTheme, width: 761, scale: 2)(request.code), first.size)
    XCTAssertTrue(renderer.imageProvider(theme: darkTheme, width: 761, scale: 2)(request.code) === first.image)
    XCTAssertNil(renderer.imageProvider(theme: lightTheme, width: 760, scale: 2)(request.code))

    renderer.shutDown()
    try await waitUntil { !renderer.engine.isRunning }
    let recording = RenderRecording()
    let second = await render(renderer, request, recording: recording)
    XCTAssertTrue(second.image === first.image)
    XCTAssertEqual(recording.recordedEvents, ["size", "image"])
    XCTAssertFalse(renderer.engine.isRunning, "a cache hit does not start WebKit")
    XCTAssertEqual(renderer.engine.startCount, 1)
  }

  func testConcurrentIdenticalRequestsAreCoalesced() async throws {
    let renderer = MermaidRenderer()
    let request = MermaidRequest(code: "flowchart LR\n  X --> Y", theme: darkTheme, width: 500, scale: 2)
    async let first = render(renderer, request)
    async let second = render(renderer, request)
    let (a, b) = await (first, second)
    XCTAssertTrue(a.image === b.image)
  }

  func testIdleShutdownThenRestart() async throws {
    let renderer = MermaidRenderer(configuration: .init(idleTimeout: 0.3))
    XCTAssertFalse(renderer.engine.isRunning, "WebKit starts lazily")
    let first = await render(
      renderer, MermaidRequest(code: "flowchart LR\n  A --> B", theme: darkTheme, width: 400, scale: 1))
    XCTAssertNil(first.failure)
    XCTAssertTrue(renderer.engine.isRunning)
    try await waitUntil { !renderer.engine.isRunning }

    let second = await render(
      renderer, MermaidRequest(code: "flowchart LR\n  C --> D", theme: darkTheme, width: 400, scale: 1))
    XCTAssertNil(second.failure)
    XCTAssertEqual(renderer.engine.startCount, 2)
    XCTAssertTrue(renderer.engine.isRunning)
    try await waitUntil { !renderer.engine.isRunning }
  }

  func testThemeChangeChangesCacheKey() throws {
    let code = try sampleFlowchart()
    let dark = MermaidRequest(code: code, theme: darkTheme, width: 760, scale: 2)
    XCTAssertNotEqual(dark.key, MermaidRequest(code: code, theme: lightTheme, width: 760, scale: 2).key)
    XCTAssertEqual(
      dark.key,
      MermaidRequest(code: code, theme: MermaidTheme(palette: .fallback(dark: true)), width: 763, scale: 2).key)
    XCTAssertNotEqual(dark.key, MermaidRequest(code: code, theme: darkTheme, width: 770, scale: 2).key)
    XCTAssertNotEqual(dark.key, MermaidRequest(code: code, theme: darkTheme, width: 760, scale: 1).key)
    XCTAssertNotEqual(dark.key, MermaidRequest(code: code + " ", theme: darkTheme, width: 760, scale: 2).key)
    var tinted = RenderPalette.fallback(dark: true)
    tinted.link = RGB(hex: 0x00ff00)
    XCTAssertNotEqual(
      dark.key, MermaidRequest(code: code, theme: MermaidTheme(palette: tinted), width: 760, scale: 2).key)
  }

  func testThemeVariablesFollowThePalette() {
    let palette = RenderPalette.fallback(dark: true)
    let theme = MermaidTheme(palette: palette)
    XCTAssertTrue(theme.dark)
    XCTAssertEqual(theme.variables["background"], palette.pageBackground.description)
    XCTAssertEqual(theme.variables["primaryTextColor"], palette.text.description)
    XCTAssertEqual(theme.variables["lineColor"], palette.mutedText.description)
    XCTAssertEqual(theme.variables["primaryBorderColor"], palette.link.description)
    XCTAssertEqual(theme.variables["fontSize"], "14px")
    XCTAssertEqual(theme.variables["fontFamily"], MermaidTheme.defaultFontFamily)
  }

}
