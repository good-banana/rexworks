import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout
import XCTest

@testable import MDViewerRender

final class ReviewFixTests: XCTestCase {
  private let dark = RenderPalette.fallback(dark: true)

  private func render(
    _ page: PageLayout, palette: RenderPalette, overlay: RenderOverlay = RenderOverlay(),
    highlights: [BlockID: HighlightResult] = [:]
  ) throws -> RasterBitmap {
    try XCTUnwrap(
      Rasterizer(layout: page, palette: palette, highlights: highlights).render(
        CGRect(x: 0, y: 0, width: page.width, height: page.height), overlay: overlay))
  }

  private func highlight(_ code: String, language: String?, using highlighter: SyntaxHighlighter) -> HighlightResult {
    let done = expectation(description: "highlight")
    nonisolated(unsafe) var output: HighlightResult?
    highlighter.highlight(code: code, language: language, queue: DispatchQueue(label: "fix")) {
      output = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return output ?? HighlightResult(outcome: .failed)
  }

  private func strongest(_ bitmap: RasterBitmap, x: Range<Int>, y: Range<Int>, against background: RGB) -> PixelColor? {
    var best: (PixelColor, Int)?
    for row in y {
      for column in x {
        guard let pixel = bitmap.pixel(x: column, y: row) else { continue }
        let distance = pixel.distance(to: background.pixel)
        if best == nil || distance > best!.1 { best = (pixel, distance) }
      }
    }
    return best?.0
  }

  private func rgb(_ pixel: PixelColor) -> RGB {
    RGB(Double(pixel.r) / 255, Double(pixel.g) / 255, Double(pixel.b) / 255)
  }

  func testStatusBarSecondaryTextMeetsContrastInRexThemes() throws {
    let palettes = themePalettes()
    for theme in ["charcoal-atelier", "merino-light", "midnight-tundra"] {
      let palette = try XCTUnwrap(palettes[theme] ?? palettes["merino-dark"], theme)
      for token in [palette.statusMutedText, palette.statusHintText, palette.statusBarText] {
        XCTAssertGreaterThanOrEqual(token.contrast(with: palette.statusBarBackground), 4.5, theme)
      }
      let bitmap = try XCTUnwrap(RasterBitmap(width: 900, height: 44))
      let content = StatusBarContent(
        fileName: "a.md", folder: "IIIIIIII", progress: ScrollProgress(start: 0, fraction: 1), hint: "llllllll")
      StatusBar(palette: palette, backingScale: 2).draw(
        content, in: CGRect(x: 0, y: 0, width: 900, height: 44), bitmap: bitmap)
      let background = palette.statusBarBackground
      let folder = try XCTUnwrap(strongest(bitmap, x: 20..<60, y: 8..<40, against: background))
      let hint = try XCTUnwrap(strongest(bitmap, x: 820..<880, y: 8..<40, against: background))
      assertColor(folder, palette.statusMutedText, tolerance: 12, "\(theme) folder")
      assertColor(hint, palette.statusHintText, tolerance: 12, "\(theme) hint")
      XCTAssertGreaterThanOrEqual(rgb(folder).contrast(with: background), 4.3, "\(theme) folder pixels")
      XCTAssertGreaterThanOrEqual(rgb(hint).contrast(with: background), 4.3, "\(theme) hint pixels")
    }
  }

  func testCopyGlyphStrokesAllSidesOfTheBackSquare() throws {
    let bitmap = try XCTUnwrap(RasterBitmap(width: 40, height: 40))
    let context = bitmap.context
    context.translateBy(x: 0, y: 40)
    context.scaleBy(x: 1, y: -1)
    let color = dark.text
    Glyphs(context: context, hairline: 1).copy(in: CGRect(x: 0, y: 0, width: 40, height: 40), color: color.cgColor)
    func inked(_ x: Int, _ y: Int) -> Bool { (bitmap.pixel(x: x, y: y)?.a ?? 0) > 160 }
    XCTAssertTrue(inked(2, 18) || inked(3, 18), "back left")
    XCTAssertTrue(inked(18, 2) || inked(18, 3), "back top")
    XCTAssertTrue(inked(25, 8) || inked(26, 8), "back right above the front square")
    XCTAssertTrue(inked(8, 25) || inked(8, 26), "back bottom left of the front square")
    XCTAssertFalse(inked(20, 20), "the gap around the front square stays clear")
    XCTAssertTrue(inked(37, 26) || inked(36, 26), "front right")
    XCTAssertTrue(inked(26, 37) || inked(26, 36), "front bottom")
  }

  func testFindHighlightsFollowRegionScrolling() throws {
    let markdown = "```\n" + String(repeating: "filler ", count: 30) + "needle\n```\n"
    let base = prepare(markdown).layout(width: 600)
    let region = try XCTUnwrap(base.regions.first)
    let matches = base.find("needle")
    XCTAssertEqual(matches.count, 1)
    let scrolled = prepare(markdown).layout(LayoutInput(width: 600, scrollOffsets: [region.id: region.maxOffset]))
    let rect = try XCTUnwrap(scrolled.rects(for: matches[0].range).first).rect
    XCTAssertTrue(matches[0].rects.allSatisfy { $0.rect != rect })
    let bitmap = try render(scrolled, palette: dark, overlay: RenderOverlay(findMatches: matches, currentMatch: 0))
    assertColor(bitmap.pixel(CGPoint(x: rect.midX, y: rect.minY + 2)), dark.currentMatchHighlight, "moved match")
  }

  func testTokensAfterTabAndEmojiOnALaterLine() throws {
    let code = "x = 1\n\t\"\u{1F600}\" + \"word\""
    let prepared = prepare("```python\n\(code)\n```\n")
    let page = prepared.layout(width: 900)
    let id = try XCTUnwrap(prepared.codeBlocks.keys.first)
    let result = highlight(try XCTUnwrap(prepared.codeBlocks[id]).code, language: "python", using: sharedHighlighter)
    let target = try XCTUnwrap(page.range(of: "word"))
    let rect = try XCTUnwrap(page.rects(for: target).first).rect
    let colored = try render(page, palette: dark, highlights: [id: result])
    var hits = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
      for x in Int(rect.minX)..<Int(rect.maxX)
      where colored.pixel(x: x, y: y)?.distance(to: dark.syntax.string.pixel) ?? 99 <= 6 {
        hits += 1
      }
    }
    XCTAssertGreaterThan(hits, 10)
  }

  func testStaleTokensAreIgnored() throws {
    let old = "def a():\n    return 1"
    let prepared = prepare("```python\nclass B:\n    pass\n```\n")
    let page = prepared.layout(width: 800)
    let id = try XCTUnwrap(prepared.codeBlocks.keys.first)
    let stale = highlight(old, language: "python", using: sharedHighlighter)
    let plain = try render(page, palette: dark)
    let drawn = try render(page, palette: dark, highlights: [id: stale])
    XCTAssertEqual(plain.pngData(), drawn.pngData())
  }

  func testDrawAtNonZeroOriginMatchesFullRender() throws {
    let page = prepare(try fixture("elements")).layout(width: 900)
    let rasterizer = Rasterizer(layout: page, palette: dark)
    let full = try XCTUnwrap(rasterizer.render(CGRect(x: 0, y: 0, width: page.width, height: page.height)))
    let canvas = try XCTUnwrap(RasterBitmap(width: 1000, height: 300))
    let source = CGRect(x: 0, y: 700, width: 900, height: 200)
    rasterizer.draw(source, into: canvas, at: CGPoint(x: 30, y: 40))
    var mismatches = 0
    for y in stride(from: 0, to: 200, by: 3) {
      for x in stride(from: 0, to: 900, by: 4) {
        let expected = try XCTUnwrap(full.pixel(x: x, y: y + 700))
        if canvas.pixel(x: x + 30, y: y + 40).map({ $0.distance(to: expected) > 8 }) ?? true { mismatches += 1 }
      }
    }
    XCTAssertEqual(mismatches, 0)
    XCTAssertEqual(canvas.pixel(x: 10, y: 10)?.a, 0, "outside the target area stays untouched")
  }

  func testInvalidRectsRenderNothing() {
    let rasterizer = Rasterizer(layout: prepare("Hi").layout(width: 400), palette: dark)
    XCTAssertNil(rasterizer.render(.zero))
    XCTAssertNil(rasterizer.render(CGRect(x: 0, y: CGFloat.nan, width: 10, height: 10)))
    XCTAssertNil(rasterizer.render(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)))
    XCTAssertNil(rasterizer.render(CGRect(x: 0, y: 0, width: 10, height: 10), scale: 0))
    XCTAssertNil(rasterizer.renderViewport(scrollY: 0, size: CGSize(width: 0, height: 100)))
    XCTAssertNil(rasterizer.renderViewport(scrollY: .infinity, size: CGSize(width: 10, height: 10)))
  }

  func testMarkUsesItsOwnColor() throws {
    let page = prepare("a <mark>marked text</mark> b").layout(width: 800)
    let box = try XCTUnwrap(page.decorations { $0 == .inlineBox(.mark) }.first).rect
    let bitmap = try render(page, palette: dark)
    assertColor(bitmap.pixel(CGPoint(x: box.minX + 1, y: box.minY + 1)), dark.markHighlight, "mark")
    XCTAssertNotEqual(dark.markHighlight.pixel, dark.findHighlight.pixel)
  }

  func testWideTableFadesUseRowColors() throws {
    let header = (1...12).map { "Column \($0)" }.joined(separator: " | ")
    let row = (1...12).map { "value \($0)" }.joined(separator: " | ")
    let markdown =
      "| \(header) |\n|" + String(repeating: " --- |", count: 12) + "\n| \(row) |\n| \(row) |\n| \(row) |\n"
    let base = prepare(markdown).layout(width: 700)
    let region = try XCTUnwrap(base.regions.first)
    let page = prepare(markdown).layout(LayoutInput(width: 700, scrollOffsets: [region.id: region.maxOffset / 2]))
    let bitmap = try render(page, palette: dark)
    let headerFill = try XCTUnwrap(page.decorations { $0 == .tableHeaderFill }.first).rect
    let stripe = try XCTUnwrap(page.decorations { $0 == .tableStripe }.first).rect
    assertColor(bitmap.pixel(CGPoint(x: region.rect.maxX - 1, y: headerFill.midY)), dark.tableHeaderFill, "header fade")
    assertColor(bitmap.pixel(CGPoint(x: region.rect.minX + 1, y: stripe.midY)), dark.tableStripe, "stripe fade")
  }

  func testNestedTablesDoNotCompoundTheTableScale() throws {
    let markdown = "<table><tr><td>Outer<table><tr><td>Inner</td></tr></table></td></tr></table>"
    let page = prepare(markdown).layout(width: 800)
    let text = page.prepared.text
    let sizes = page.prepared.segments.reduce(into: [String: CGFloat]()) {
      $0[text.substring(with: NSRange($1.range)).trimmingCharacters(in: .whitespaces)] = $1.fontSize
    }
    let outer = try XCTUnwrap(sizes["Outer"])
    XCTAssertEqual(try XCTUnwrap(sizes["Inner"]), outer, accuracy: 0.01)
    XCTAssertEqual(outer, page.prepared.typography.bodyPixelSize * 14 / 15, accuracy: 0.01)
  }

  func testSlowHighlightsAreAbandonedAndSkipped() {
    var configuration = SyntaxHighlighter.Configuration()
    configuration.timeout = 0.001
    let highlighter = SyntaxHighlighter(configuration: configuration)
    let code = String(repeating: "value = compute(item) + 1\n", count: 400)
    XCTAssertEqual(highlight(code, language: nil, using: highlighter).outcome, .timedOut)
    XCTAssertEqual(highlighter.scriptRuns, 1)
    XCTAssertEqual(highlight(code + "more = 2\n", language: nil, using: highlighter).outcome, .timedOut)
    XCTAssertEqual(highlighter.scriptRuns, 1)
    XCTAssertEqual(highlighter.enginesCreated, 1)
  }

  func testCacheIsBoundedBySpanCount() {
    var configuration = SyntaxHighlighter.Configuration()
    configuration.cacheSpanLimit = 20
    let highlighter = SyntaxHighlighter(configuration: configuration)
    let first = "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\nlet e = 5"
    let second = "let f = 6\nlet g = 7\nlet h = 8\nlet i = 9\nlet j = 10"
    XCTAssertTrue(highlight(first, language: "swift", using: highlighter).isHighlighted)
    XCTAssertTrue(highlight(second, language: "swift", using: highlighter).isHighlighted)
    XCTAssertNil(highlighter.cached(code: first, language: "swift"))
    XCTAssertNotNil(highlighter.cached(code: second, language: "swift"))
  }

  func testAtMostOneAbandonedEngineRunsAtATime() {
    var configuration = SyntaxHighlighter.Configuration()
    configuration.timeout = 0.001
    let highlighter = SyntaxHighlighter(configuration: configuration)
    let body = String(repeating: "value = compute(item, other) + 1 # note\n", count: 3_000)
    for (index, language) in [nil, "python", "swift", "javascript", "ruby", nil, "go", "rust", "c"].enumerated() {
      let code = String(repeating: "x", count: index) + body
      XCTAssertEqual(highlight(code, language: language, using: highlighter).outcome, .timedOut, language ?? "auto")
    }
    XCTAssertEqual(highlighter.mostAbandonedRunning, 1)
    XCTAssertLessThanOrEqual(highlighter.enginesCreated, 9)
    XCTAssertNil(highlighter.cached(code: body, language: "swift"), "busy refusals are not cached")
  }

  func testColdLoadIsOutsideTheWatchdogBudget() {
    var configuration = SyntaxHighlighter.Configuration()
    configuration.timeout = 0.02
    let highlighter = SyntaxHighlighter(configuration: configuration)
    XCTAssertTrue(highlight("let a = 1", language: "swift", using: highlighter).isHighlighted)
  }
}
