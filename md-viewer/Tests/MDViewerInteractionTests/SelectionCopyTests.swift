import CoreGraphics
import MDViewerCore
import MDViewerLayout
import MDViewerRender
import XCTest

@testable import MDViewerInteraction

final class SelectionTests: XCTestCase {
  let text = "Alpha beta gamma delta.\n\nSecond paragraph here.\n\nThird block of text."

  func testDragSelectsAndRedrawsOnlyTheChangedLines() {
    var h = Harness(text)
    let start = h.point(of: "beta", at: 0)
    XCTAssertEqual(h.mouse(.press, at: start), [], "a press on unselected text changes nothing")
    h.mouse(.motion, at: CGPoint(x: start.x + 1, y: start.y))
    XCTAssertNil(h.model.selection, "movement under the threshold is not a drag")
    let effects = h.mouse(.motion, at: h.point(of: "gamma", at: 1))
    XCTAssertEqual(h.model.selection.map { h.layout.plainText($0) }, "beta gamma")
    XCTAssertFalse(effects.redrawRects.isEmpty)
    XCTAssertFalse(effects.hasFullRedraw)
    h.mouse(.motion, at: h.point(of: "here", at: 1))
    XCTAssertEqual(h.model.selection.map { h.layout.plainText($0) }, "beta gamma delta.\n\nSecond paragraph here")
    h.mouse(.release, at: h.point(of: "here", at: 1))
    XCTAssertTrue(h.clipboard.isEmpty, "auto-copy is off")
  }

  func testDoubleClickSelectsAWordAndDragExtendsByWords() {
    var h = Harness(text)
    let beta = h.point(of: "beta")
    h.click(beta)
    h.mouse(.press, at: beta, advance: 100_000_000)
    XCTAssertEqual(h.model.selection, h.range(of: "beta"))
    h.mouse(.motion, at: h.point(of: "gamma", at: 0.3))
    XCTAssertEqual(h.model.selection.map { h.layout.plainText($0) }, "beta gamma")
    h.mouse(.release, at: h.point(of: "gamma"))
  }

  func testTripleClickSelectsTheParagraph() {
    var h = Harness(text)
    let point = h.point(of: "paragraph")
    h.click(point)
    h.click(point, advance: 100_000_000)
    h.mouse(.press, at: point, advance: 100_000_000)
    XCTAssertEqual(h.model.selection.map { h.layout.plainText($0) }, "Second paragraph here.")
    h.mouse(.release, at: point)
    h.click(point, advance: 100_000_000)
    XCTAssertEqual(
      h.model.selection.map { h.layout.plainText($0) }, "Second paragraph here.", "a fourth click stays at the block")
    h.click(point, advance: second)
    XCTAssertNil(h.model.selection, "a later click starts over")
  }

  func testShiftClickNoLongerExtends() {
    var h = Harness(text)
    h.click(h.point(of: "beta", at: 0))
    h.click(h.point(of: "paragraph", at: 1), modifiers: .shift)
    XCTAssertNil(h.model.selection, "Rex strips Shift from clicks, so a Shift-click is a plain click")
  }

  func testSelectionInsideARegion() {
    var h = Harness("Intro\n\n" + wideCode)
    let region = h.layout.regions.first { $0.maxOffset > 0 }!
    let start = h.point(of: "let", at: 0)
    h.mouse(.press, at: start)
    h.mouse(.motion, at: h.point(of: "value", at: 1))
    XCTAssertEqual(h.model.selection.map { h.layout.plainText($0) }, "let value")
    h.mouse(.release, at: h.point(of: "value", at: 1))
    h.mouse(.wheelRight, at: CGPoint(x: region.rect.midX, y: region.rect.midY))
    XCTAssertEqual(h.model.selection.map { h.layout.plainText($0) }, "let value", "scrolling keeps the selection")
  }

  func testDragNearTheBottomEdgeAutoScrollsAndExtends() {
    var h = Harness(longDocument())
    h.mouse(.press, at: h.point(of: "Paragraph 1 ", at: 0))
    h.paneMouse(.motion, x: 300, y: 595)
    let first = h.model.selection!
    XCTAssertNotNil(h.model.nextDeadline)
    XCTAssertEqual(h.model.offset, 0)
    h.tick(by: 40_000_000)
    XCTAssertGreaterThan(h.model.offset, 0)
    h.tick(by: 40_000_000)
    XCTAssertGreaterThan(h.model.selection!.upperBound, first.upperBound)
    h.paneMouse(.motion, x: 300, y: 300)
    let resting = h.model.offset
    h.tick(by: 40_000_000)
    XCTAssertEqual(h.model.offset, resting, "auto-scroll stops away from the edge")
    h.paneMouse(.release, x: 300, y: 300)
    XCTAssertNil(h.model.nextDeadline.flatMap { $0 <= h.now ? $0 : nil })
  }

  func testDragNearARegionEdgeScrollsTheRegion() {
    var h = Harness("Intro\n\n" + wideCode)
    let region = h.layout.regions.first { $0.maxOffset > 0 }!
    let start = h.point(of: "let", at: 0)
    let edge = CGPoint(x: region.rect.maxX - 4, y: start.y)
    h.mouse(.press, at: start)
    h.mouse(.motion, at: edge)
    let first = h.model.selection!
    h.tick(by: 40_000_000)
    h.tick(by: 40_000_000)
    XCTAssertGreaterThan(h.layout.region(region.id)!.offset, 0)
    XCTAssertGreaterThan(h.model.selection!.upperBound, first.upperBound, "the selection follows the scrolled text")
    h.mouse(.release, at: edge)
  }

  func testEscapePriorityFindThenSelectionThenFocus() {
    var h = Harness("[link](#x) alpha beta alpha\n\n# X")
    h.click(h.point(of: "beta"))
    h.click(h.point(of: "beta"), advance: 100_000_000)
    XCTAssertNotNil(h.model.selection)
    h.key(.tab)
    XCTAssertNotNil(h.model.focus)
    h.key(.char("/"))
    h.keys("alpha")
    XCTAssertEqual(h.model.overlay.findMatches.count, 2)
    h.key(.escape)
    XCTAssertNil(h.model.findField)
    XCTAssertNil(h.model.findQuery)
    XCTAssertNotNil(h.model.selection)
    h.key(.char("/"))
    h.keys("alpha")
    h.key(.enter)
    XCTAssertNotNil(h.model.findQuery)
    h.key(.escape)
    XCTAssertNil(h.model.findQuery, "find goes first")
    XCTAssertTrue(h.model.overlay.findMatches.isEmpty)
    XCTAssertNotNil(h.model.selection)
    h.key(.escape)
    XCTAssertNil(h.model.selection, "then the selection")
    XCTAssertNotNil(h.model.focus)
    h.key(.escape)
    XCTAssertNil(h.model.focus, "then focus")
    XCTAssertEqual(h.key(.escape), [])
  }
}

final class CopyTests: XCTestCase {
  let text = "Some **bold** words here.\n\nNext line."

  func select(_ h: inout Harness, from: String, to: String) {
    h.mouse(.press, at: h.point(of: from, at: 0))
    h.mouse(.motion, at: h.point(of: to, at: 1))
    h.mouse(.release, at: h.point(of: to, at: 1))
  }

  func testYCopiesPlainTextAndCapitalYCopiesMarkdown() {
    var h = Harness(text)
    XCTAssertEqual(h.key(.char("y")), [.redrawStatusBar])
    XCTAssertEqual(h.model.status.message?.text, "Nothing selected")
    select(&h, from: "Some", to: "words")
    h.key(.char("y"))
    XCTAssertEqual(h.decodedClipboard(), "Some bold words")
    XCTAssertEqual(h.model.status.message, StatusMessage("Copied 15 characters", kind: .success))
    h.key(.char("Y"))
    XCTAssertEqual(h.decodedClipboard(), "Some **bold** words here.")
  }

  func testCommandCFromTheKittyKeyboardProtocolCopies() {
    var h = Harness(text)
    select(&h, from: "bold", to: "words")
    h.bytes("\u{1b}[99;9u")
    XCTAssertEqual(h.decodedClipboard(), "bold words")
  }

  func testAutoCopyFollowsTheRexPreference() {
    var h = Harness(text, copyOnSelect: true)
    select(&h, from: "Some", to: "bold")
    XCTAssertEqual(h.decodedClipboard(), "Some bold")
    h.click(h.point(of: "Next"))
    XCTAssertEqual(h.clipboard.count, 1, "a plain click copies nothing")

    h.system.copyOnSelect = false
    select(&h, from: "Next", to: "line")
    XCTAssertEqual(h.clipboard.count, 1, "the preference is re-read on each selection release")
    XCTAssertFalse(h.model.copyOnSelect)
    h.system.copyOnSelect = true
    h.key(.char("r"))
    XCTAssertTrue(h.model.copyOnSelect, "and on r")
    select(&h, from: "Some", to: "words")
    XCTAssertEqual(h.clipboard.count, 2)
  }

  func testReloadKeyAsksTheHostToReload() {
    var h = Harness(text)
    XCTAssertEqual(h.key(.char("r")), [.reload])
  }

  func testCopyPillSharesOneRectWithItsHitTarget() throws {
    var h = Harness("```\nlet x = 1\n```")
    let area = try XCTUnwrap(
      h.layout.targets.first {
        if case .copyCode = $0.target { return true }
        return false
      })
    let typography = h.layout.prepared.typography
    let content =
      typography.pixels(em: CopyButtonMetrics.paddingScale) * 2 + typography.pixels(em: CopyButtonMetrics.iconScale)
      + typography.pixels(em: CopyButtonMetrics.gapScale)
      + CopyButtonMetrics.labelWidth(CopyButtonMetrics.copiedLabel, typography: typography)
    XCTAssertGreaterThanOrEqual(area.rect.width, content, "the target fits the widest label")
    let decoration = try XCTUnwrap(h.layout.decorations.first { $0.kind == .copyButton })
    XCTAssertEqual(decoration.rect, area.rect)

    h.mouse(.motion, at: CGPoint(x: area.rect.midX, y: area.rect.midY), button: 3)
    XCTAssertEqual(h.model.overlay.copyButton, CopyButtonOverlay(block: BlockID(0)).withBlock(area.target))
    let leftEdge = CGPoint(x: area.rect.minX + 2, y: area.rect.midY)
    XCTAssertEqual(h.layout.target(at: leftEdge), area.target, "the left part of the drawn pill is clickable")
    let effects = h.click(leftEdge)
    XCTAssertEqual(h.decodedClipboard(), "let x = 1")
    XCTAssertEqual(h.model.overlay.copyButton?.copied, true)
    XCTAssertTrue(effects.redrawRects.contains { $0.contains(area.rect) })
    XCTAssertEqual(h.model.status.message?.text, "Copied 9 characters")
    h.tick(by: 2 * second)
    XCTAssertEqual(h.model.overlay.copyButton?.copied, false, "Copied reverts while still hovered")
    h.mouse(.motion, at: CGPoint(x: 5, y: 5), button: 3)
    XCTAssertNil(h.model.overlay.copyButton)
  }

  func testCopyPillDrawsInsideItsTarget() throws {
    let markdown = "```\nlet x = 1\n```"
    let page = PreparedDocument(markdown: markdown).layout(width: 800)
    let area = try XCTUnwrap(page.targets.first { if case .copyCode = $0.target { true } else { false } })
    let background = try XCTUnwrap(page.decorations.first { $0.kind == .codeBlockBackground })
    let palette = RenderPalette(
      colors: TerminalColorSet(foreground: RGB(hex: 0xdddddd), background: RGB(hex: 0x1e1e1e), colorScheme: .dark))
    let rasterizer = Rasterizer(layout: page, palette: palette)
    for copied in [false, true] {
      let overlay = RenderOverlay(copyButton: CopyButtonOverlay(block: BlockID(0), copied: copied))
      let plain = try XCTUnwrap(rasterizer.render(background.rect, overlay: RenderOverlay()))
      let drawn = try XCTUnwrap(rasterizer.render(background.rect, overlay: overlay))
      var outside = 0
      var inside = 0
      for y in 0..<drawn.height {
        for x in 0..<drawn.width where drawn.pixel(x: x, y: y) != plain.pixel(x: x, y: y) {
          let point = CGPoint(x: background.rect.minX + CGFloat(x) + 0.5, y: background.rect.minY + CGFloat(y) + 0.5)
          if area.rect.insetBy(dx: -1, dy: -1).contains(point) { inside += 1 } else { outside += 1 }
        }
      }
      XCTAssertGreaterThan(inside, 0)
      XCTAssertEqual(outside, 0, "the pill never draws outside its hit target (copied: \(copied))")
    }
  }

  func testCKeyAndEnterCopyAFocusedCodeBlock() {
    var h = Harness("```\nfirst\n```")
    XCTAssertEqual(h.key(.char("c")), [])
    h.key(.tab)
    h.key(.char("c"))
    XCTAssertEqual(h.decodedClipboard(), "first")
    h.key(.enter)
    XCTAssertEqual(h.clipboard.count, 2)
  }

  func testCopiesCarryTheMarkdownFlag() {
    var h = Harness(text)
    h.key(.command("a"))
    h.key(.char("y"))
    h.key(.char("Y"))
    XCTAssertEqual(h.clipboardMarkdown, [false, true])
    XCTAssertEqual(h.model.copy("", at: h.now), [.redrawStatusBar])
    XCTAssertEqual(h.model.status.message?.text, "Nothing to copy")
  }

  func testMessagesExpire() {
    var h = Harness(text)
    h.key(.char("y"))
    XCTAssertNotNil(h.model.status.message)
    XCTAssertEqual(h.tick(by: 100_000_000), [])
    XCTAssertEqual(h.tick(by: 3 * second), [.redrawStatusBar])
    XCTAssertNil(h.model.status.message)
  }
}

extension CopyButtonOverlay {
  func withBlock(_ target: HitTarget) -> CopyButtonOverlay {
    guard case .copyCode(let id, _) = target else { return self }
    return CopyButtonOverlay(block: id, copied: copied)
  }
}
