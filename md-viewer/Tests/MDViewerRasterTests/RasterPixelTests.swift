import CoreGraphics
import MDViewerCore
import MDViewerLayout
import XCTest

@testable import MDViewerRender

final class RasterPixelTests: XCTestCase {
  private let dark = RenderPalette.fallback(dark: true)
  private let light = RenderPalette.fallback(dark: false)

  private func render(
    _ page: PageLayout, palette: RenderPalette, overlay: RenderOverlay = RenderOverlay(),
    highlights: [BlockID: HighlightResult] = [:], assets: RenderAssets = RenderAssets()
  ) throws -> RasterBitmap {
    let rasterizer = Rasterizer(layout: page, palette: palette, assets: assets, highlights: highlights)
    return try XCTUnwrap(
      rasterizer.render(CGRect(x: 0, y: 0, width: page.width, height: page.height), overlay: overlay))
  }

  func testPageAndCodeBlockBackgrounds() throws {
    let page = prepare("Intro\n\n```\nlet x = 1\n```\n").layout(width: 800)
    let bitmap = try render(page, palette: dark)
    let box = try XCTUnwrap(page.decorations { $0 == .codeBlockBackground }.first).rect
    assertColor(bitmap.pixel(CGPoint(x: box.minX + 20, y: box.maxY - 4)), dark.codeBlockBackground, "code background")
    assertColor(bitmap.pixel(CGPoint(x: 2, y: 2)), dark.pageBackground, "page background")
  }

  func testTableHeaderFillBorderAndStripe() throws {
    let markdown = "| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n| 5 | 6 |\n"
    let page = prepare(markdown).layout(width: 800)
    let bitmap = try render(page, palette: light)
    let header = try XCTUnwrap(page.decorations { $0 == .tableHeaderFill }.first).rect
    assertColor(bitmap.pixel(CGPoint(x: header.minX + 6, y: header.minY + 6)), light.tableHeaderFill, "header fill")
    let edge = Int(header.maxY.rounded())
    for y in [edge - 1, edge] {
      assertColor(bitmap.pixel(x: Int(header.midX), y: y), light.border, "header border row \(y)")
    }
    assertColor(bitmap.pixel(CGPoint(x: header.minX + 6, y: header.maxY + 6)), light.pageBackground, "first row")
    let stripe = try XCTUnwrap(page.decorations { $0 == .tableStripe }.first).rect
    assertColor(bitmap.pixel(CGPoint(x: stripe.minX + 6, y: stripe.minY + 6)), light.tableStripe, "stripe")
    let cell = try XCTUnwrap(page.decorations { $0 == .tableCellBorder }.last).rect
    assertColor(bitmap.pixel(CGPoint(x: cell.maxX - 1, y: cell.midY)), light.border, "outer right border")
    assertColor(bitmap.pixel(CGPoint(x: cell.midX, y: cell.maxY - 1)), light.border, "outer bottom border")
  }

  func testTableTextIsSmallerThanBody() throws {
    let page = prepare("Body\n\n| Cell |\n| --- |\n| Text |\n").layout(width: 800)
    let segments = page.prepared.segments
    let body = try XCTUnwrap(segments.first { page.prepared.text.substring(with: NSRange($0.range)) == "Body" })
    let cell = try XCTUnwrap(segments.first { page.prepared.text.substring(with: NSRange($0.range)) == "Text" })
    XCTAssertEqual(cell.fontSize / body.fontSize, 14.0 / 15.0, accuracy: 0.001)
  }

  func testAlertBarAndIconUseAlertColor() throws {
    let page = prepare("> [!NOTE]\n> Useful information.\n").layout(width: 800)
    let bitmap = try render(page, palette: dark)
    let bar = try XCTUnwrap(page.decorations { $0 == .alertBar(.note) }.first).rect
    assertColor(bitmap.pixel(CGPoint(x: bar.midX, y: bar.midY)), dark.alerts.note, "alert bar")
    let icon = try XCTUnwrap(page.decorations { $0 == .alertIcon(.note) }.first).rect
    var found = false
    for x in Int(icon.minX)..<Int(icon.maxX) where !found {
      found = bitmap.pixel(x: x, y: Int(icon.midY)).map { $0.distance(to: dark.alerts.note.pixel) <= 3 } ?? false
    }
    XCTAssertTrue(found, "icon is drawn in the alert color")
  }

  func testSelectionFindAndCurrentMatch() throws {
    let page = prepare("alpha beta alpha gamma alpha").layout(width: 1200)
    let selection = try XCTUnwrap(page.range(of: "gamma"))
    let matches = page.find("alpha")
    XCTAssertEqual(matches.count, 3)
    let bitmap = try render(
      page, palette: dark, overlay: RenderOverlay(selection: selection, findMatches: matches, currentMatch: 1))
    func probe(_ rect: CGRect) -> PixelColor? { bitmap.pixel(CGPoint(x: rect.midX, y: rect.minY + 2)) }
    assertColor(probe(try XCTUnwrap(page.rects(for: selection).first).rect), dark.selectionFill, "selection")
    assertColor(probe(try XCTUnwrap(matches[0].rects.first).rect), dark.findHighlight, "match")
    assertColor(probe(try XCTUnwrap(matches[1].rects.first).rect), dark.currentMatchHighlight, "current match")
    XCTAssertNotEqual(dark.findHighlight.pixel, dark.currentMatchHighlight.pixel)
  }

  func testStatusBarProgressAndBackground() throws {
    let bitmap = try XCTUnwrap(RasterBitmap(width: 800, height: 40))
    let content = StatusBarContent(fileName: "a.md", progress: ScrollProgress(start: 0.4, fraction: 0.2))
    StatusBar(palette: dark, backingScale: 2).draw(
      content, in: CGRect(x: 0, y: 0, width: 800, height: 40), bitmap: bitmap)
    assertColor(bitmap.pixel(x: 400, y: 1), dark.progressFill, "thumb")
    assertColor(bitmap.pixel(x: 100, y: 1), dark.progressTrack, "track before")
    assertColor(bitmap.pixel(x: 700, y: 1), dark.progressTrack, "track after")
    assertColor(bitmap.pixel(x: 600, y: 25), dark.statusBarBackground, "background")
  }

  func testViewportPlacesStatusBarAtBottom() throws {
    let page = prepare(String(repeating: "Paragraph text.\n\n", count: 80)).layout(width: 600)
    let rasterizer = Rasterizer(layout: page, palette: light)
    let height = StatusBar.height(cellPixelHeight: 34, backingScale: 2)
    let status = StatusBarContent(
      fileName: "long.md", progress: ScrollProgress(offset: page.height * 0.4, viewport: 500, content: page.height))
    let frame = try XCTUnwrap(
      rasterizer.renderViewport(
        scrollY: page.height * 0.4, size: CGSize(width: 600, height: 600), status: status, statusBarHeight: height))
    let top = 600 - Int(height)
    assertColor(frame.pixel(x: 243, y: top + 1), light.progressFill, "thumb at 40%")
    assertColor(frame.pixel(x: 20, y: top + 1), light.progressTrack, "track")
    assertColor(frame.pixel(x: 590, y: 599), light.statusBarBackground, "bar background")
  }

  func testStatusBarHeightFollowsCellGrid() {
    XCTAssertEqual(StatusBar.height(cellPixelHeight: 34, backingScale: 2), 34)
    XCTAssertEqual(StatusBar.height(cellPixelHeight: 26, backingScale: 2), 52)
    XCTAssertEqual(StatusBar.height(cellPixelHeight: 18, backingScale: 1), 18)
    XCTAssertEqual(StatusBar.height(cellPixelHeight: 0, backingScale: 2), 44)
  }

  func testScrollRegionClipsShiftedContent() throws {
    let line = String(repeating: "wide_identifier ", count: 20)
    let markdown = "```\n\(line)\n```\n"
    let base = prepare(markdown).layout(width: 600)
    let region = try XCTUnwrap(base.regions.first)
    XCTAssertGreaterThan(region.maxOffset, 300)
    let shifted = prepare(markdown).layout(LayoutInput(width: 600, scrollOffsets: [region.id: 300]))
    let bitmap = try render(shifted, palette: dark)
    let fragment = try XCTUnwrap(shifted.fragments.first)
    for x in 0..<Int(region.rect.minX) {
      for y in stride(from: Int(fragment.lineTop), to: Int(fragment.lineBottom), by: 2) {
        assertColor(bitmap.pixel(x: x, y: y), dark.pageBackground, "left of region at \(x),\(y)")
      }
    }
    for x in Int(region.rect.maxX) + 1..<Int(shifted.width) {
      assertColor(bitmap.pixel(x: x, y: Int(fragment.origin.y) - 4), dark.pageBackground, "right of region at \(x)")
    }
    let unshifted = try render(base, palette: dark)
    var differs = false
    for x in stride(from: Int(region.rect.minX) + 40, to: Int(region.rect.maxX) - 40, by: 3) where !differs {
      differs =
        bitmap.pixel(x: x, y: Int(fragment.origin.y) - 6) != unshifted.pixel(x: x, y: Int(fragment.origin.y) - 6)
    }
    XCTAssertTrue(differs, "the offset moves the content")
    var thumb = false
    for x in Int(region.rect.minX)..<Int(region.rect.maxX) where !thumb {
      thumb =
        bitmap.pixel(x: x, y: Int(region.rect.maxY) - 8).map { $0.distance(to: dark.codeBlockBackground.pixel) > 20 }
        ?? false
    }
    XCTAssertTrue(thumb, "an overflowing region draws a scroll thumb")
  }

  func testRightToLeftBlocksDrawBarsOnTheRight() throws {
    let page = prepare(
      "> \u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD}\n\n> [!NOTE]\n> \u{05E9}\u{05DC}\u{05D5}\u{05DD}\n"
    )
    .layout(width: 800)
    let bitmap = try render(page, palette: light)
    let quote = try XCTUnwrap(page.decorations { $0 == .blockquoteBar }.first).rect
    let alert = try XCTUnwrap(page.decorations { $0 == .alertBar(.note) }.first).rect
    let left = page.prepared.typography.pixels(em: page.prepared.typography.pageMarginSide)
    for bar in [quote, alert] {
      XCTAssertGreaterThan(bar.minX, page.width / 2)
      assertColor(bitmap.pixel(CGPoint(x: left + 1, y: bar.midY)), light.pageBackground, "left edge is empty")
    }
    assertColor(bitmap.pixel(CGPoint(x: quote.midX, y: quote.midY)), light.blockquoteBar, "quote bar on the right")
    assertColor(bitmap.pixel(CGPoint(x: alert.midX, y: alert.midY)), light.alerts.note, "alert bar on the right")
  }

  func testFrontMatterBoxAndBar() throws {
    let page = prepare("---\ntitle: Hello\n---\n\nBody\n").layout(width: 800)
    let bitmap = try render(page, palette: dark)
    let box = try XCTUnwrap(page.decorations { $0 == .frontMatterBackground }.first).rect
    let bar = try XCTUnwrap(page.decorations { $0 == .frontMatterBar }.first).rect
    assertColor(bitmap.pixel(CGPoint(x: box.maxX - 4, y: box.midY)), dark.frontmatterBackground, "box")
    assertColor(bitmap.pixel(CGPoint(x: bar.midX, y: bar.midY)), dark.frontmatterBar, "bar")
    let key = try XCTUnwrap(page.fragments.first)
    XCTAssertTrue(
      CTFontGetSymbolicTraits(try firstFont(page.prepared.segments[key.segment].line)).contains(.traitMonoSpace))
  }

  private func firstFont(_ line: CTLine) throws -> CTFont {
    let run = try XCTUnwrap((CTLineGetGlyphRuns(line) as? [CTRun])?.first)
    let font = try XCTUnwrap((CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String])
    return font as! CTFont
  }

  func testTaskBoxesCheckedAndUnchecked() throws {
    let page = prepare("- [x] done\n- [ ] open\n").layout(width: 800)
    let bitmap = try render(page, palette: light)
    let boxes = page.decorations { if case .taskBox = $0 { return true } else { return false } }
    XCTAssertEqual(boxes.count, 2)
    assertColor(bitmap.pixel(CGPoint(x: boxes[0].rect.minX + 2, y: boxes[0].rect.midY)), light.link, "checked fill")
    assertColor(bitmap.pixel(CGPoint(x: boxes[1].rect.midX, y: boxes[1].rect.midY)), light.pageBackground, "unchecked")
  }

  func testImagesComeFromTheAssetCache() throws {
    let page = prepare("![alt](pic.png)").layout(
      LayoutInput(width: 800, imageSize: { _ in CGSize(width: 40, height: 20) }))
    let box = try XCTUnwrap(page.images.first).rect
    let solid = try XCTUnwrap(RasterBitmap(width: 4, height: 4))
    solid.context.setFillColor(light.alerts.important.cgColor)
    solid.context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let picture = try XCTUnwrap(solid.makeImage())
    let assets = RenderAssets(image: { $0 == "pic.png" ? picture : nil })
    let drawn = try render(page, palette: light, assets: assets)
    assertColor(drawn.pixel(CGPoint(x: box.midX, y: box.midY)), light.alerts.important, "image pixels")
    let placeholder = try render(page, palette: light)
    assertColor(placeholder.pixel(CGPoint(x: box.minX + 5, y: box.midY)), light.inlineCodeBackground, "placeholder")
  }

  func testCopyButtonAndFocusOutlineAreOverlays() throws {
    let page = prepare("```\ncode\n```\n").layout(width: 800)
    let id = try XCTUnwrap(page.prepared.codeBlocks.keys.first)
    let button = try XCTUnwrap(page.decorations { $0 == .copyButton }.first).rect
    let probe = CGPoint(x: button.maxX - 3, y: button.midY)
    let idle = try render(page, palette: dark)
    assertColor(idle.pixel(probe), dark.codeBlockBackground, "hidden without hover")
    let hovered = try render(page, palette: dark, overlay: RenderOverlay(copyButton: CopyButtonOverlay(block: id)))
    assertColor(hovered.pixel(probe), dark.inlineCodeBackground, "shown on hover")
    let focused = try render(page, palette: dark, overlay: RenderOverlay(focus: .codeBlock(id)))
    let box = try XCTUnwrap(page.decorations { $0 == .codeBlockBackground }.first).rect
    let hairline = max(1, page.prepared.typography.pixels(cssPoints: 1).rounded())
    assertColor(focused.pixel(CGPoint(x: box.midX, y: box.minY - hairline * 2)), dark.focusOutline, "focus ring")
  }

  func testStripMatchesFullRender() throws {
    let page = prepare(try fixture("elements")).layout(width: 1000)
    let rasterizer = Rasterizer(layout: page, palette: dark)
    let full = try XCTUnwrap(rasterizer.render(CGRect(x: 0, y: 0, width: page.width, height: page.height)))
    let strip = CGRect(x: 0, y: 1203, width: page.width, height: 120)
    let partial = try XCTUnwrap(rasterizer.render(strip))
    var mismatches = 0
    for y in stride(from: 0, to: 120, by: 3) {
      for x in stride(from: 0, to: Int(page.width), by: 5) {
        let expected = try XCTUnwrap(full.pixel(x: x, y: y + Int(strip.minY)))
        if partial.pixel(x: x, y: y).map({ $0.distance(to: expected) > 8 }) ?? true { mismatches += 1 }
      }
    }
    XCTAssertEqual(mismatches, 0)
  }

  func testHalfScaleRenderUsesPageCoordinates() throws {
    let page = prepare("```\nx\n```\n").layout(width: 800)
    let box = try XCTUnwrap(page.decorations { $0 == .codeBlockBackground }.first).rect
    let bitmap = try XCTUnwrap(
      Rasterizer(layout: page, palette: dark).render(CGRect(x: 0, y: 0, width: 800, height: page.height), scale: 0.5))
    XCTAssertEqual(bitmap.width, 400)
    assertColor(bitmap.pixel(CGPoint(x: box.midX / 2, y: box.maxY / 2 - 3)), dark.codeBlockBackground, "scaled")
  }
}
