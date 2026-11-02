import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerDocument
import MDViewerLayout
import MDViewerMermaid
import XCTest

@testable import MDViewerRender

final class ScreenshotTests: XCTestCase {
  private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../..").standardizedFileURL

  @MainActor
  func testWriteReadmeScreenshots() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["MDVIEWER_SCREENSHOTS"] == "1", "set MDVIEWER_SCREENSHOTS=1 to write")
    let review = root.appendingPathComponent(".build/review-images/task9-images")
    try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
    let source = try String(contentsOf: root.appendingPathComponent("docs/sample.md"), encoding: .utf8)
    let typography = Typography(bodySize: Typography.defaultBodySize, zoom: 1, backingScale: 2)
    let prepared = PreparedDocument(markdown: source, typography: typography)
    let highlights = highlightAll(prepared)
    let width: CGFloat = 760 * 2
    let statusHeight = StatusBar.height(cellPixelHeight: 34, backingScale: 2)
    let palettes = themePalettes()
    let mermaid = MermaidRenderer()
    for (theme, name) in [("charcoal-atelier", "dark"), ("merino-light", "light")] {
      let palette = try XCTUnwrap(palettes[theme])
      let mermaidTheme = MermaidTheme(palette: palette)
      let margin = typography.pixels(em: typography.pageMarginSide)
      let columnWidth = (width - margin * 2) / typography.scale
      for block in prepared.codeBlocks.values where block.isDiagram {
        let diagram = await withCheckedContinuation { continuation in
          mermaid.render(
            MermaidRequest(code: block.code, theme: mermaidTheme, width: columnWidth, scale: typography.scale)
          ) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(diagram.failure)
      }
      let page = prepared.layout(
        LayoutInput(
          width: width, expandedDetails: prepared.initiallyExpandedDetails, prefersDark: palette.dark,
          diagramSize: mermaid.sizeProvider(theme: mermaidTheme, width: columnWidth, scale: typography.scale)))
      XCTAssertGreaterThanOrEqual(page.regions.filter { $0.maxOffset > 0 }.count, 2, "wide table and code scroll")
      let rasterizer = Rasterizer(
        layout: page, palette: palette,
        assets: RenderAssets(
          diagram: mermaid.imageProvider(theme: mermaidTheme, width: columnWidth, scale: typography.scale)),
        highlights: highlights)
      let height = page.height + statusHeight
      let bitmap = try XCTUnwrap(RasterBitmap(width: Int(width), height: Int(height.rounded(.up))))
      rasterizer.draw(CGRect(x: 0, y: 0, width: width, height: page.height), into: bitmap)
      let status = StatusBarContent(
        fileName: "sample.md", folder: "~/projects/search/docs", progress: ScrollProgress(start: 0, fraction: 1))
      StatusBar(palette: palette, backingScale: 2).draw(
        status, in: CGRect(x: 0, y: page.height, width: width, height: statusHeight), bitmap: bitmap)
      let data = try XCTUnwrap(bitmap.pngData())
      try data.write(to: root.appendingPathComponent("docs/preview-\(name).png"))
      try data.write(to: review.appendingPathComponent("preview-\(name).png"))

      let viewport = CGSize(width: width, height: 1400)
      let crop = try XCTUnwrap(
        rasterizer.renderViewport(
          scrollY: 0, size: viewport, status: status.withProgress(page.height, viewport.height - statusHeight),
          statusBarHeight: statusHeight))
      try XCTUnwrap(crop.pngData()).write(to: review.appendingPathComponent("viewport-\(name).png"))
    }
  }
}

extension StatusBarContent {
  fileprivate func withProgress(_ content: CGFloat, _ viewport: CGFloat) -> StatusBarContent {
    var copy = self
    copy.progress = ScrollProgress(offset: 0, viewport: viewport, content: content)
    return copy
  }
}
