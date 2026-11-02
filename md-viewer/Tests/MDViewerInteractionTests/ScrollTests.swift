import CoreGraphics
import MDViewerCore
import MDViewerLayout
import MDViewerRender
import XCTest

@testable import MDViewerInteraction

final class ScrollTests: XCTestCase {
  func testKeysScrollInWholeRowsAndClamp() {
    var h = Harness(longDocument())
    let row: CGFloat = 30
    XCTAssertGreaterThan(h.model.maximumOffset, 600)
    XCTAssertEqual(h.model.maximumOffset.truncatingRemainder(dividingBy: row), 0)

    XCTAssertEqual(h.key(.char("j")), [.scroll(to: 90)])
    h.key(.down)
    XCTAssertEqual(h.model.offset, 180)
    h.key(.char("k"))
    h.key(.up)
    XCTAssertEqual(h.model.offset, 0)
    XCTAssertEqual(h.key(.up), [], "already at the top")

    h.key(.char("d"))
    XCTAssertEqual(h.model.offset, 300)
    h.key(.char("u"))
    XCTAssertEqual(h.model.offset, 0)
    h.key(.char(" "))
    XCTAssertEqual(h.model.offset, 600)
    h.key(.pageDown)
    XCTAssertEqual(h.model.offset, 1200)
    h.key(.char("b"))
    h.key(.pageUp)
    XCTAssertEqual(h.model.offset, 0)

    h.key(.char("G"))
    XCTAssertEqual(h.model.offset, h.model.maximumOffset)
    XCTAssertEqual(h.key(.end), [])
    XCTAssertEqual(h.key(.char("j")), [], "clamped at the bottom")
    h.key(.char("g"))
    XCTAssertEqual(h.model.offset, 0)
    h.key(.end)
    h.key(.home)
    XCTAssertEqual(h.model.offset, 0)
  }

  func testShortDocumentNeverScrolls() {
    var h = Harness("# Short\n\nOne line.")
    XCTAssertEqual(h.model.maximumOffset, 0)
    XCTAssertEqual(h.key(.char("G")), [])
    XCTAssertEqual(h.send(.mouse(MouseEvent(kind: .wheelDown, x: 10, y: 10))), [])
  }

  func testWheelScrollsOneRowAndAccelerates() {
    var h = Harness(longDocument())
    XCTAssertEqual(h.send(.mouse(MouseEvent(kind: .wheelDown, x: 10, y: 10)), advance: second), [.scroll(to: 30)])
    for _ in 0..<12 { h.send(.mouse(MouseEvent(kind: .wheelDown, x: 10, y: 10)), advance: 10_000_000) }
    XCTAssertGreaterThan(h.model.offset, 30 * 13, "a fast streak moves more than a row per event")
    let before = h.model.offset
    h.send(.mouse(MouseEvent(kind: .wheelUp, x: 10, y: 10)), advance: second)
    XCTAssertEqual(h.model.offset, before - 30, "a pause resets the streak")
  }

  func testWheelAccelerator() {
    var wheel = WheelAccelerator(streakWindow: 50)
    XCTAssertEqual(wheel.multiplier(direction: 1, at: 1000), 1)
    var last = 1
    for step in 1...20 { last = wheel.multiplier(direction: 1, at: 1000 + UInt64(step) * 10) }
    XCTAssertEqual(last, WheelAccelerator.maximumMultiplier)
    XCTAssertEqual(wheel.multiplier(direction: -1, at: 1220), 1, "a direction change resets")
    XCTAssertEqual(wheel.multiplier(direction: -1, at: 9000), 1, "a pause resets")
  }

  func testResizeKeepsTheTopContentAndClamps() {
    var h = Harness(longDocument())
    h.key(.char("d"))
    h.key(.char("d"))
    let top = h.model.topLine(in: h.layout)!.range.lowerBound
    h.run(h.model.resize(ViewGeometry(width: 700, contentHeight: 600, rowHeight: 30)))
    XCTAssertEqual(h.layout.width, 700)
    let fragment = h.model.topLine(in: h.layout)!
    XCTAssertLessThanOrEqual(abs(fragment.range.lowerBound - top), 80, "the same paragraph stays at the top")
    h.run(h.model.resize(ViewGeometry(width: 700, contentHeight: 100_000, rowHeight: 30)))
    XCTAssertEqual(h.model.offset, 0)
  }
}

final class RegionScrollTests: XCTestCase {
  func region(_ h: Harness) -> ScrollRegion { h.layout.regions.first { $0.maxOffset > 0 }! }

  func testHorizontalWheelScrollsOnlyTheRegionUnderThePointer() {
    var h = Harness("Intro\n\n" + wideCode + "\n\nAfter")
    let area = region(h)
    let inside = CGPoint(x: area.rect.midX, y: area.rect.midY)
    let effects = h.mouse(.wheelRight, at: inside)
    XCTAssertEqual(effects.first, .layoutChanged)
    XCTAssertEqual(effects.redrawRects, [area.rect], "only the region's patch is redrawn")
    XCTAssertFalse(effects.hasFullRedraw)
    XCTAssertGreaterThan(region(h).offset, 0)
    XCTAssertEqual(h.model.offset, 0)

    h.mouse(.wheelLeft, at: inside, advance: second)
    XCTAssertEqual(region(h).offset, 0)
    XCTAssertEqual(h.mouse(.wheelLeft, at: inside, advance: second), [], "clamped at the left edge")

    let outside = h.point(of: "Intro")
    XCTAssertEqual(h.mouse(.wheelRight, at: outside), [])
  }

  func testShiftWheelScrollsTheRegionSideways() {
    var h = Harness("Intro\n\n" + wideCode)
    let area = region(h)
    h.mouse(.wheelDown, at: CGPoint(x: area.rect.midX, y: area.rect.midY), modifiers: .shift)
    XCTAssertGreaterThan(region(h).offset, 0)
    for _ in 0..<200 { h.mouse(.wheelDown, at: CGPoint(x: area.rect.midX, y: area.rect.midY), modifiers: .shift) }
    XCTAssertEqual(region(h).offset, region(h).maxOffset, "clamped at the right edge")
  }

  func testFocusedRegionKeysAndTheBackRule() {
    var h = Harness(
      "[other](other.md)\n\n" + wideCode, files: ["/docs/other.md": "# Other"])
    h.click(h.point(of: "other"))
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    h.key(.tab)
    XCTAssertNil(h.model.focus, "no focusables in the other document")

    h.key(.backspace)
    XCTAssertEqual(h.model.file?.lastPathComponent, "guide.md")
    h.key(.tab)
    XCTAssertEqual(h.model.focus, .link(h.range(of: "other")!, href: "other.md"))
    h.key(.tab)
    guard case .codeBlock(let id) = h.model.focus else { return XCTFail("code block is focusable") }
    XCTAssertEqual(h.model.overlay.focus, .codeBlock(id))

    h.key(.char("l"))
    XCTAssertGreaterThan(region(h).offset, 0)
    h.key(.right)
    let afterRight = region(h).offset
    h.key(.left)
    XCTAssertLessThan(region(h).offset, afterRight)
    h.key(.char("h"))
    XCTAssertEqual(region(h).offset, 0)
    h.key(.char("h"))
    h.key(.backspace)
    XCTAssertEqual(h.model.file?.lastPathComponent, "guide.md", "h and Backspace never go back with a region focused")
    XCTAssertEqual(h.loads.count, 2)

    h.key(.escape)
    XCTAssertNil(h.model.focus)
    h.key(.char("h"))
    XCTAssertEqual(h.model.history.canGoBack, false)
  }

  func testTabCyclesLinksDetailsCodeAndTables() {
    let table =
      "| " + (1...30).map { "column\($0)" }.joined(separator: " | ") + " |\n|"
      + String(repeating: "---|", count: 30) + "\n| " + (1...30).map { "v\($0)" }.joined(separator: " | ") + " |"
    var h = Harness(
      "[a](#x)\n\n<details><summary>More</summary>\n\nBody\n\n</details>\n\n```\ncode\n```\n\n" + table)
    var seen: [Focusable] = []
    for _ in 0..<4 {
      h.key(.tab)
      seen.append(h.model.focus!)
    }
    XCTAssertEqual(seen.count, 4)
    guard case .link = seen[0], case .details = seen[1], case .codeBlock = seen[2], case .table(let id) = seen[3]
    else { return XCTFail("unexpected order \(seen)") }
    XCTAssertEqual(h.model.overlay.focus, .region(id))
    h.key(.tab)
    XCTAssertEqual(h.model.focus, seen[0], "wraps around")
    h.key(.backTab)
    XCTAssertEqual(h.model.focus, seen[3])
  }

  func testDraggingTheScrollbarMovesTheRegion() {
    var h = Harness("Intro\n\n" + wideCode)
    let area = region(h)
    let bar = RegionScrollbar(region: area, typography: h.layout.prepared.typography)!
    let grab = CGPoint(x: bar.thumb.midX, y: bar.thumb.midY)
    XCTAssertEqual(h.mouse(.press, at: grab), [], "pressing the thumb does not jump")
    h.mouse(.motion, at: CGPoint(x: grab.x + bar.track.width / 2, y: grab.y))
    XCTAssertGreaterThan(region(h).offset, 0)
    h.mouse(.motion, at: CGPoint(x: bar.track.maxX + 500, y: grab.y))
    XCTAssertEqual(region(h).offset, area.maxOffset)
    h.mouse(.release, at: CGPoint(x: bar.track.maxX + 500, y: grab.y))
    XCTAssertNil(h.model.selection, "a scrollbar drag never selects")

    h.mouse(.press, at: CGPoint(x: bar.track.minX + 2, y: grab.y), advance: second)
    XCTAssertEqual(region(h).offset, 0, "pressing the track jumps the thumb there")
    h.mouse(.release, at: CGPoint(x: bar.track.minX + 2, y: grab.y))
  }

  func testLeftAndRightUseTheRegionUnderThePointerWithoutFocus() {
    var h = Harness("Intro\n\n" + wideCode)
    let area = region(h)
    h.mouse(.motion, at: CGPoint(x: area.rect.midX, y: area.rect.midY), button: 3)
    h.key(.right)
    XCTAssertGreaterThan(region(h).offset, 0)
    h.mouse(.motion, at: h.point(of: "Intro"), button: 3)
    let offset = region(h).offset
    XCTAssertEqual(h.key(.left), [])
    XCTAssertEqual(region(h).offset, offset)
  }
}
