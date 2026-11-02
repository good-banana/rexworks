import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout
import XCTest

@testable import MDViewerInteraction

final class FindWindowTests: XCTestCase {
  func testWindowStartsAtTheViewAndMovesAtItsEdges() {
    var h = Harness(String(repeating: "word ", count: 7000), height: 600)
    h.key(.char("G"))
    let viewStart = h.model.topLine(in: h.layout)!.range.lowerBound
    XCTAssertGreaterThan(viewStart, 5000 * 5, "the view starts after the 5,000th match")
    h.key(.char("/"))
    h.keys("word")
    h.key(.enter)
    XCTAssertTrue(h.model.findWindowed)
    XCTAssertEqual(h.model.overlay.findMatches.count, ViewerInteraction.findLimit)
    let first = h.model.overlay.findMatches[0].range
    XCTAssertGreaterThanOrEqual(first.lowerBound, viewStart, "the window begins where the view is")
    XCTAssertLessThan(first.lowerBound, viewStart + 10)
    XCTAssertEqual(h.model.overlay.currentMatch, 0)
    XCTAssertEqual(h.model.status.message?.text, "1/\(ViewerInteraction.findLimit)+")
    let wrapped = h.model.overlay.findMatches[ViewerInteraction.findLimit - 1].range
    XCTAssertLessThan(wrapped.lowerBound, viewStart, "the window wraps to the top")

    h.key(.char("N"))
    let last = h.model.overlay.findMatches.count - 1
    XCTAssertEqual(h.model.overlay.currentMatch, last, "N past the window's start loads the previous window")
    XCTAssertEqual(h.model.overlay.findMatches[last].range.upperBound, first.lowerBound - 1)
    h.key(.char("n"))
    XCTAssertEqual(h.model.overlay.currentMatch, 0, "n past the window's end loads the next window")
    XCTAssertEqual(h.model.overlay.findMatches[0].range, first)
  }

  func testSmallResultSetsStayInDocumentOrder() {
    var h = Harness("alpha beta alpha gamma alpha")
    h.key(.char("/"))
    h.keys("alpha")
    XCTAssertFalse(h.model.findWindowed)
    XCTAssertEqual(h.model.overlay.findMatches.map(\.range.lowerBound), [0, 11, 23])
    XCTAssertEqual(h.model.status.message?.text, "1/3")
  }

  func testLayoutFindWrapsForwardAndBackward() {
    let page = PreparedDocument(markdown: "a1 a2 a3 a4").layout(width: 800)
    XCTAssertEqual(page.find("a", from: 4).map(\.range.lowerBound), [6, 9, 0, 3])
    XCTAssertEqual(page.find("a", from: 4, limit: 2).map(\.range.lowerBound), [6, 9])
    XCTAssertEqual(page.find("a", from: 4, backward: true).map(\.range.lowerBound), [3, 0, 9, 6])
  }
}

final class PointerFocusTests: XCTestCase {
  func document() -> String {
    "[down](#end)\n\n" + wideCode + "\n\n" + longDocument() + "\n\n## End"
  }

  func dragInCode(_ h: inout Harness) {
    h.mouse(.press, at: h.point(of: "let", at: 0))
    h.mouse(.motion, at: h.point(of: "value", at: 1))
    h.mouse(.release, at: h.point(of: "value", at: 1))
  }

  func testBackspaceGoesBackAfterDragSelectingInACodeBlock() {
    var h = Harness(document())
    h.run(h.model.jump(toAnchor: "end", at: h.now))
    h.key(.char("g"))
    dragInCode(&h)
    guard case .codeBlock = h.model.focus else { return XCTFail("pointer focus on the code block") }
    XCTAssertTrue(h.model.focusFromPointer)
    h.key(.backspace)
    XCTAssertTrue(h.model.history.canGoForward, "Backspace went back")
  }

  func testEnterAndCDoNothingUnderPointerFocus() {
    var h = Harness(document())
    dragInCode(&h)
    h.key(.enter)
    h.key(.char("c"))
    XCTAssertTrue(h.clipboard.isEmpty)
    h.key(.char("l"))
    XCTAssertGreaterThan(h.layout.regions.first { $0.maxOffset > 0 }!.offset, 0, "l still scrolls the clicked region")
    h.key(.tab)
    XCTAssertFalse(h.model.focusFromPointer)
  }

  func testAnchorClickLeavesNoStaleHint() {
    var h = Harness(document())
    h.click(h.point(of: "down"))
    XCTAssertGreaterThan(h.model.offset, 0)
    XCTAssertNil(h.model.status.hint)
  }
}

final class ReloadRaceTests: XCTestCase {
  let original =
    "Intro.\n\n<details><summary>Keep open</summary>\n\nInside.\n\n</details>\n\n<details><summary>Closed</summary>\n\nHidden.\n\n</details>\n\n"
    + wideCode

  func prepared(_ h: inout Harness) -> CGFloat {
    h.click(h.point(of: "Keep open"))
    let region = h.layout.regions.first { $0.maxOffset > 0 }!
    h.mouse(.wheelRight, at: CGPoint(x: region.rect.midX, y: region.rect.midY))
    h.key(.tab)
    h.key(.tab)
    return h.layout.region(region.id)!.offset
  }

  func expandedSummaries(_ h: Harness) -> Set<String> {
    let identities = BlockIdentity.details(in: h.layout.prepared)
    return Set(h.layout.expandedDetails.compactMap { identities[$0]?.text })
  }

  func finish(_ h: inout Harness, _ effects: [InteractionEffect]) {
    let request = effects.layoutRequests.last!
    XCTAssertNotNil(request.carriedDetails, "the remap survives")
    h.run(h.model.apply(request.perform(), for: request))
  }

  func testZoomDuringAPendingReloadKeepsTheRemap() {
    var h = Harness(original)
    let scrolled = prepared(&h)
    let edited = "Inserted.\n\n<details><summary>New</summary>\n\nX.\n\n</details>\n\n" + original
    h.system.files["/docs/guide.md"] = edited
    _ = h.model.fileChanged(source: edited)
    let effects = h.model.handle(.key(.char("+")), at: h.now)
    finish(&h, effects)
    XCTAssertEqual(h.layout.prepared.typography.zoom, 1.1)
    XCTAssertEqual(expandedSummaries(h), ["Keep open"])
    let region = h.layout.regions.first { $0.maxOffset > 0 }!
    XCTAssertEqual(region.offset, min(scrolled, region.maxOffset))
    XCTAssertEqual(h.model.focus, .codeBlock(region.id))
  }

  func testDetailsToggleDuringAPendingReloadIsFolded() {
    var h = Harness(original)
    _ = prepared(&h)
    let closed = h.point(of: "Closed")
    let edited = "Inserted.\n\n" + original
    _ = h.model.fileChanged(source: edited)
    let (x, y) = h.pane(closed)
    _ = h.model.handle(.mouse(MouseEvent(kind: .press, x: x, y: y)), at: h.now + second)
    let effects = h.model.handle(.mouse(MouseEvent(kind: .release, x: x, y: y)), at: h.now + second + 1)
    finish(&h, effects)
    XCTAssertEqual(expandedSummaries(h), ["Keep open", "Closed"])
    XCTAssertGreaterThan(h.layout.regions.first { $0.maxOffset > 0 }!.offset, 0)
  }
}
