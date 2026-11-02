import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout
import MDViewerRender
import XCTest

@testable import MDViewerInteraction

func wideTable(link: Bool = false) -> String {
  let columns = 30
  let header = "| " + (1...columns).map { "column\($0)" }.joined(separator: " | ") + " |"
  let rule = "|" + String(repeating: "---|", count: columns)
  let row =
    "| " + (1...columns).map { $0 == columns && link ? "[far](#far)" : "v\($0)" }.joined(separator: " | ") + " |"
  return [header, rule, row].joined(separator: "\n")
}

final class PointerFixTests: XCTestCase {
  func testMissedReleaseEndsTheDrag() {
    var h = Harness(longDocument())
    h.mouse(.press, at: h.point(of: "Paragraph 1 ", at: 0))
    h.paneMouse(.motion, x: 300, y: 595)
    XCTAssertNotNil(h.model.nextDeadline)
    h.paneMouse(.release, x: 300, y: 595, button: 1)
    XCTAssertNotNil(h.model.press, "another button's release does not end a left drag")
    h.paneMouse(.motion, x: 300, y: 595, button: 3)
    XCTAssertNil(h.model.press, "motion with no button held ends a drag whose release was missed")
    XCTAssertNil(h.model.autoScrollDeadline)
    let offset = h.model.offset
    h.tick(by: second)
    XCTAssertEqual(h.model.offset, offset, "no runaway auto-scroll")
    XCTAssertNotNil(h.model.selection)
  }

  func testClickMovesOrClearsFocus() {
    var h = Harness("[link](other.md) intro text\n\n" + wideCode, files: ["/docs/other.md": "# Other"])
    h.key(.tab)
    h.key(.tab)
    guard case .codeBlock(let id) = h.model.focus else { return XCTFail("code block focused") }
    XCTAssertNotNil(h.model.overlay.focus)
    h.click(h.point(of: "intro"))
    XCTAssertNil(h.model.focus, "a click on plain text clears focus")
    XCTAssertNil(h.model.overlay.focus)

    h.click(h.point(of: "value"))
    XCTAssertEqual(h.model.focus, .codeBlock(id), "a click in a code block focuses it")
    XCTAssertNil(h.model.overlay.focus, "pointer focus draws no ring")
    h.key(.char("l"))
    XCTAssertGreaterThan(h.layout.region(id)!.offset, 0)
    h.key(.char("h"))
    XCTAssertEqual(h.layout.region(id)!.offset, 0)
    XCTAssertTrue(h.loads.isEmpty)
  }

  func testOffscreenFocusedRegionLetsBackspaceGoBack() {
    var h = Harness(wideCode + "\n\n" + longDocument() + "\n\n## End")
    h.key(.tab)
    guard case .codeBlock = h.model.focus else { return XCTFail("code block focused") }
    XCTAssertNotNil(h.model.focusedRegion)
    XCTAssertEqual(h.key(.backspace), [], "Backspace is swallowed while the region is on screen")
    h.run(h.model.jump(toAnchor: "end", at: h.now))
    XCTAssertGreaterThan(h.model.offset, 0)
    XCTAssertNotNil(h.model.focus)
    XCTAssertNil(h.model.focusedRegion, "an off-screen region does not count as focused")
    h.key(.backspace)
    XCTAssertEqual(h.model.offset, 0, "Backspace went back")
  }

  func testTabReachesLinksScrolledOutOfARegion() {
    var h = Harness("Intro\n\n" + wideTable(link: true) + "\n\n## Far")
    let range = h.range(of: "far")!
    XCTAssertTrue(h.layout.rects(for: range).isEmpty, "the link starts clipped out")
    h.key(.tab)
    h.key(.tab)
    XCTAssertEqual(h.model.focus, .link(range, href: "#far"))
    XCTAssertFalse(h.layout.rects(for: range).isEmpty, "focus scrolled the region to the link")
  }

  func testSelectAll() {
    var h = Harness("One.\n\nTwo.")
    h.key(.command("a"))
    XCTAssertEqual(h.model.selection.map { h.layout.plainText($0) }, "One.\n\nTwo.")
    h.key(.char("y"))
    XCTAssertEqual(h.decodedClipboard(), "One.\n\nTwo.")
  }
}

final class LayoutFixTests: XCTestCase {
  func testReloadRemapsDetailsRegionsAndFocus() {
    let original =
      "Intro.\n\n<details><summary>Keep open</summary>\n\nInside.\n\n</details>\n\n<details><summary>Closed</summary>\n\nHidden.\n\n</details>\n\n"
      + wideCode
    var h = Harness(original)
    h.click(h.point(of: "Keep open"))
    let region = h.layout.regions.first { $0.maxOffset > 0 }!
    h.mouse(.wheelRight, at: CGPoint(x: region.rect.midX, y: region.rect.midY))
    h.mouse(.wheelRight, at: CGPoint(x: region.rect.midX, y: region.rect.midY), advance: second)
    let scrolled = h.layout.region(region.id)!.offset
    XCTAssertGreaterThan(scrolled, 0)
    XCTAssertEqual(h.model.focus.map { if case .details = $0 { true } else { false } }, true)
    h.key(.tab)
    h.key(.tab)
    guard case .codeBlock = h.model.focus else { return XCTFail("code block focused") }

    h.reload("New first paragraph.\n\n" + "<details><summary>Inserted</summary>\n\nX.\n\n</details>\n\n" + original)
    let summaries = h.layout.prepared.detailsBlocks.map { id in
      (id, BlockIdentity.details(in: h.layout.prepared)[id]!.text)
    }
    let expanded = Set(summaries.filter { h.layout.expandedDetails.contains($0.0) }.map(\.1))
    XCTAssertEqual(expanded, ["Keep open"], "the same details stays open and the inserted one stays closed")
    let newRegion = h.layout.regions.first { $0.maxOffset > 0 }!
    XCTAssertNotEqual(newRegion.id, region.id, "block IDs shifted")
    XCTAssertEqual(newRegion.offset, scrolled, "the code block keeps its sideways scroll")
    XCTAssertEqual(h.model.focus, .codeBlock(newRegion.id), "focus follows the block")
    XCTAssertNotNil(h.model.overlay.focus)

    h.reload("Nothing left.")
    XCTAssertNil(h.model.focus, "focus clears when its block is gone")
  }

  func testReloadOpensNewDetailsMarkedOpen() {
    var h = Harness("Intro.")
    h.reload("<details open><summary>Fresh</summary>\n\nBody.\n\n</details>")
    XCTAssertEqual(h.layout.expandedDetails.count, 1)
  }

  func testPendingLayoutKeepsASidewaysScrollMadeMeanwhile() {
    var h = Harness("Intro\n\n" + wideCode)
    let region = h.layout.regions.first { $0.maxOffset > 0 }!
    let request = h.model.assetsChanged().layoutRequests[0]
    h.mouse(.wheelRight, at: CGPoint(x: region.rect.midX, y: region.rect.midY))
    let scrolled = h.layout.region(region.id)!.offset
    XCTAssertGreaterThan(scrolled, 0)
    h.run(h.model.apply(request.perform(), for: request))
    XCTAssertEqual(h.layout.region(region.id)!.offset, scrolled)
  }

  func testRapidZoomAnchorsAgainstTheShownLayout() {
    var h = Harness(longDocument())
    h.run(h.model.setOffset(900))
    let anchor = h.model.topLine(in: h.layout)!
    let delta = h.model.offset - anchor.lineTop
    _ = h.model.handle(.key(.char("+")), at: h.now)
    let effects = h.model.handle(.key(.char("+")), at: h.now + 1)
    let request = effects.layoutRequests[0]
    h.run(h.model.apply(request.perform(), for: request))
    XCTAssertEqual(h.layout.prepared.typography.zoom, 1.25)
    let newTop = h.model.lineTop(near: anchor.range.lowerBound, in: h.layout)!
    XCTAssertEqual(h.model.offset - newTop, delta * 1.25, accuracy: 15.01)
  }

  func testZoomKeepsTheAnchorWithinHalfARow() {
    var h = Harness(longDocument())
    h.run(h.model.setOffset(930))
    let anchor = h.model.topLine(in: h.layout)!
    let delta = h.model.offset - anchor.lineTop
    for (key, zoom) in [("+", 1.1), ("+", 1.25), ("-", 1.1), ("0", 1.0)] as [(Character, CGFloat)] {
      let ratio = zoom / h.layout.prepared.typography.zoom
      let anchorNow = h.model.topLine(in: h.layout)!
      let deltaNow = h.model.offset - anchorNow.lineTop
      h.key(.char(key))
      let top = h.model.lineTop(near: anchorNow.range.lowerBound, in: h.layout)!
      XCTAssertEqual(h.model.offset - top, deltaNow * ratio, accuracy: 15.01, "zoom \(zoom)")
    }
    XCTAssertEqual(h.model.offset - h.model.lineTop(near: anchor.range.lowerBound, in: h.layout)!, delta, accuracy: 30)
  }

  func testWorkerRunsOnlyTheNewestPendingLayout() {
    let worker = LayoutWorker()
    let gate = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    worker.submit {
      started.signal()
      gate.wait()
    }
    started.wait()
    final class Counter: @unchecked Sendable {
      let lock = NSLock()
      var generations: [Int] = []
    }
    let counter = Counter()
    let done = expectation(description: "newest layout")
    for generation in 1...20 {
      let request = LayoutRequest(
        generation: generation, source: "# Doc \(generation)", reuse: nil, typography: Typography(), width: 600,
        expandedDetails: nil, scrollOffsets: [:])
      worker.layout(request, providers: LayoutProviders()) { _ in
        counter.lock.lock()
        counter.generations.append(generation)
        counter.lock.unlock()
        if generation == 20 { done.fulfill() }
      }
    }
    gate.signal()
    wait(for: [done], timeout: 30)
    XCTAssertEqual(worker.perform { 1 }, 1)
    counter.lock.lock()
    XCTAssertEqual(counter.generations, [20])
    counter.lock.unlock()
  }
}

final class FindFixTests: XCTestCase {
  func testMatchesInsideCollapsedDetailsAreCountedAndRevealed() {
    var h = Harness("Visible needle.\n\n<details><summary>More</summary>\n\nHidden needle.\n\n</details>")
    h.key(.char("/"))
    h.keys("needle")
    h.key(.enter)
    XCTAssertEqual(h.model.overlay.findMatches.count, 2)
    XCTAssertTrue(h.layout.expandedDetails.isEmpty)
    h.key(.char("n"))
    XCTAssertEqual(h.model.overlay.currentMatch, 1)
    XCTAssertEqual(h.layout.expandedDetails.count, 1, "revealing a hidden match opens its details")
    XCTAssertFalse(h.model.overlay.findMatches[1].rects.isEmpty)
    XCTAssertEqual(h.model.status.message?.text, "2/2")
  }

  func testInitialMatchConsidersMatchesClippedInsideRegions() {
    var h = Harness("Intro\n\n" + wideCode + "\n\nLater needle here.")
    h.key(.char("/"))
    h.keys("needle")
    XCTAssertEqual(h.model.overlay.currentMatch, 0, "the clipped code match comes first")
    XCTAssertGreaterThan(h.layout.regions.first { $0.maxOffset > 0 }!.offset, 0)
  }

  func testRedrawsStayInTheViewportAndMatchesAreCapped() {
    var h = Harness(String(repeating: "word ", count: 6000))
    h.key(.char("/"))
    let effects = h.keys("w")
    XCTAssertEqual(h.model.overlay.findMatches.count, ViewerInteraction.findLimit)
    XCTAssertEqual(h.model.status.message?.text, "1/\(ViewerInteraction.findLimit)+")
    let visible = CGRect(x: 0, y: h.model.offset, width: 1200, height: 600)
    XCTAssertTrue(effects.redrawRects.allSatisfy { $0.intersects(visible) })
    XCTAssertLessThanOrEqual(effects.redrawRects.count, ViewerInteraction.maximumBandRedraws)
  }

  func testRegionScrollRecomputesOnlyThatRegionsMatches() {
    var h = Harness("needle intro\n\n" + wideCode)
    h.key(.char("/"))
    h.keys("needle")
    h.key(.enter)
    let outside = h.model.overlay.findMatches[0]
    let region = h.layout.regions.first { $0.maxOffset > 0 }!
    h.mouse(.wheelLeft, at: CGPoint(x: region.rect.midX, y: region.rect.midY), advance: second)
    XCTAssertEqual(h.model.overlay.findMatches[0], outside)
    XCTAssertEqual(h.model.overlay.findMatches[1].rects, h.layout.rects(for: h.model.overlay.findMatches[1].range))
  }
}

final class RegionScrollCostTests: XCTestCase {
  func testSidewaysScrollOnALargeDocumentIsCheap() throws {
    var lines: [String] = []
    for section in 1...520 {
      lines += [
        "## Section \(section)", "", "Paragraph \(section) with **strong**, `code` and a [link](https://e.com).", "",
        "- item", "- [x] task", "", "| A | B |", "| --- | --- |", "| a | b |", "", "```", "let x = \(section)", "```",
        "",
      ]
    }
    lines.insert(wideCode, at: lines.count / 2)
    let document = lines.joined(separator: "\n")
    XCTAssertGreaterThan(document.split(separator: "\n").count, 5000)
    var h = Harness(document)
    let region = try XCTUnwrap(h.layout.regions.first { $0.maxOffset > 0 })
    h.run(h.model.setOffset(region.rect.minY - 100))
    let palette = RenderPalette(
      colors: TerminalColorSet(foreground: RGB(hex: 0xdddddd), background: RGB(hex: 0x1e1e1e), colorScheme: .dark))
    var rasterizer = Rasterizer(layout: h.layout, palette: palette)
    var samples: [Double] = []
    for step in 0..<40 {
      let start = DispatchTime.now().uptimeNanoseconds
      let effects = h.mouse(
        step % 20 < 10 ? .wheelRight : .wheelLeft, at: CGPoint(x: region.rect.midX, y: region.rect.midY),
        advance: second)
      for case .regionScrolled(let id, let offset) in effects { rasterizer.setScrollOffset(offset, for: id) }
      samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
      if step == 9 { XCTAssertGreaterThan(h.layout.region(region.id)!.offset, 0) }
    }
    let rebuildStart = DispatchTime.now().uptimeNanoseconds
    _ = Rasterizer(layout: h.layout, palette: palette)
    print("rasterizer rebuild: \(Double(DispatchTime.now().uptimeNanoseconds - rebuildStart) / 1_000_000) ms")
    XCTAssertEqual(rasterizer.layout.region(region.id)?.offset, h.layout.region(region.id)?.offset)
    let median = samples.sorted()[samples.count / 2]
    print("region scroll on \(document.split(separator: "\n").count) lines: median \(median) ms")
    XCTAssertLessThan(median, 20)
  }
}
