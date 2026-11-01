import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout
import MDViewerMermaid
import XCTest

@testable import MDViewerRender

final class ReviewImageTests: XCTestCase {
  private var outputDirectory: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../.build/review-images/task4-images").standardizedFileURL
  }

  @MainActor
  func testWriteReviewImages() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["MDVIEWER_REVIEW_IMAGES"] == "1", "set MDVIEWER_REVIEW_IMAGES=1 to write")
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let palettes = themePalettes()
    let themes = ["charcoal-atelier", "merino-light", "midnight-tundra"]
    let sample = prepare(try fixture("sample"))
    let elements = prepare(try fixture("elements"))
    let sampleHighlights = highlightAll(sample)
    let elementHighlights = highlightAll(elements)
    let width: CGFloat = 760 * 2
    let statusHeight = StatusBar.height(cellPixelHeight: 34, backingScale: 2)
    let mermaid = MermaidRenderer()
    for theme in themes {
      let palette = try XCTUnwrap(palettes[theme] ?? (theme == "midnight-tundra" ? palettes["merino-dark"] : nil))
      let diagrams = try await renderDiagrams(sample, width: width, palette: palette, mermaid: mermaid)
      let page = sample.layout(
        LayoutInput(
          width: width, expandedDetails: sample.initiallyExpandedDetails, prefersDark: palette.dark,
          diagramSize: diagrams.size))
      let rasterizer = Rasterizer(
        layout: page, palette: palette, assets: RenderAssets(diagram: diagrams.image), highlights: sampleHighlights)
      let full = try XCTUnwrap(rasterizer.render(CGRect(x: 0, y: 0, width: width, height: page.height)))
      try write(full, "sample-\(theme).png")

      let viewport = CGSize(width: width, height: 1100)
      let scrollable = max(page.height - (viewport.height - statusHeight), 0)
      let scrollY = (scrollable * 0.4).rounded()
      let matches = page.find("index")
      let status = StatusBarContent(
        fileName: "sample.md", folder: "md-viewer/docs",
        progress: ScrollProgress(offset: scrollY, viewport: viewport.height - statusHeight, content: page.height),
        message: StatusMessage("3/\(matches.count)", kind: .find), hint: "/ find   y copy   q quit")
      let frame = try XCTUnwrap(
        rasterizer.renderViewport(
          scrollY: scrollY, size: viewport, overlay: RenderOverlay(findMatches: matches, currentMatch: 2),
          status: status, statusBarHeight: statusHeight))
      try write(frame, "status-40-\(theme).png")

      let elementPage = elements.layout(width: width)
      let elementRaster = Rasterizer(layout: elementPage, palette: palette, highlights: elementHighlights)
      let codeID = try XCTUnwrap(elements.codeBlocks.first { $0.value.language == "python" }?.key)
      let selection = try XCTUnwrap(elementPage.range(of: "Plain text with"))
      let task = try XCTUnwrap(
        elementPage.targets.first {
          if case .task = $0.target { return true } else { return false }
        }
      ).target
      let overlay = RenderOverlay(
        selection: selection.lowerBound..<(selection.upperBound + 20), findMatches: elementPage.find("details"),
        currentMatch: 0, focus: .target(task), copyButton: CopyButtonOverlay(block: codeID))
      let elementImage = try XCTUnwrap(
        elementRaster.render(CGRect(x: 0, y: 0, width: width, height: elementPage.height), overlay: overlay))
      try write(elementImage, "elements-\(theme).png")
    }
  }

  @MainActor
  private func renderDiagrams(
    _ prepared: PreparedDocument, width: CGFloat, palette: RenderPalette, mermaid: MermaidRenderer
  ) async throws -> (size: @Sendable (String) -> CGSize?, image: @Sendable (String) -> CGImage?) {
    let scale = prepared.typography.scale
    let placeholder = try XCTUnwrap(
      prepared.layout(width: width).images.first {
        if case .diagram = $0.content { return true } else { return false }
      })
    let theme = MermaidTheme(palette: palette)
    let columnWidth = placeholder.rect.width / scale
    for block in prepared.codeBlocks.values where block.isDiagram {
      let diagram = await withCheckedContinuation { continuation in
        mermaid.render(MermaidRequest(code: block.code, theme: theme, width: columnWidth, scale: scale)) {
          continuation.resume(returning: $0)
        }
      }
      XCTAssertNil(diagram.failure)
    }
    return (
      mermaid.sizeProvider(theme: theme, width: columnWidth, scale: scale),
      mermaid.imageProvider(theme: theme, width: columnWidth, scale: scale)
    )
  }

  private func write(_ bitmap: RasterBitmap, _ name: String) throws {
    let data = try XCTUnwrap(bitmap.pngData())
    try data.write(to: outputDirectory.appendingPathComponent(name))
  }
}
