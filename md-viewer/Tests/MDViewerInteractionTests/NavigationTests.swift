import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout
import MDViewerRender
import XCTest

@testable import MDViewerInteraction

final class FindTests: XCTestCase {
  func testTypingFindsLiveAndEnterCommits() {
    var h = Harness("Apple pie. apple tart. APPLE juice. Pear.")
    h.key(.char("/"))
    XCTAssertEqual(h.model.findField, "")
    XCTAssertEqual(h.model.status.findField, "")
    h.keys("app")
    XCTAssertEqual(h.model.overlay.findMatches.count, 3, "lowercase is case-insensitive")
    XCTAssertEqual(h.model.status.message, StatusMessage("1/3", kind: .find))
    XCTAssertEqual(h.model.status.findField, "app")
    h.key(.backspace)
    XCTAssertEqual(h.model.findField, "ap")
    h.keys("p")
    h.key(.enter)
    XCTAssertNil(h.model.findField)
    XCTAssertEqual(h.model.findQuery, "app")
    XCTAssertEqual(h.model.overlay.currentMatch, 0)

    h.key(.char("n"))
    XCTAssertEqual(h.model.overlay.currentMatch, 1)
    XCTAssertEqual(h.model.status.message?.text, "2/3")
    h.key(.char("n"))
    h.key(.char("n"))
    XCTAssertEqual(h.model.overlay.currentMatch, 0, "wraps")
    h.key(.char("N"))
    XCTAssertEqual(h.model.overlay.currentMatch, 2)
  }

  func testSmartCase() {
    var h = Harness("Apple pie. apple tart. APPLE juice.")
    h.key(.char("/"))
    h.keys("Apple")
    XCTAssertEqual(h.model.overlay.findMatches.map(\.range), [h.range(of: "Apple")!])
    h.key(.escape)
    h.key(.char("/"))
    h.keys("APPLE")
    XCTAssertEqual(h.model.overlay.findMatches.count, 1)
    XCTAssertTrue(ViewerInteraction.isCaseSensitive("aB"))
    XCTAssertFalse(ViewerInteraction.isCaseSensitive("ab1"))
  }

  func testEscapeCancelsAndRestoresAndBackspaceOnEmptyCloses() {
    var h = Harness(longDocument() + "\n\nunique needle")
    h.key(.char("/"))
    h.keys("needle")
    XCTAssertGreaterThan(h.model.offset, 0, "scrolled to the match")
    h.key(.escape)
    XCTAssertEqual(h.model.offset, 0, "cancel restores the position")
    XCTAssertNil(h.model.findQuery)
    XCTAssertTrue(h.model.overlay.findMatches.isEmpty)

    h.key(.char("/"))
    h.key(.backspace)
    XCTAssertNil(h.model.findField)
    XCTAssertEqual(h.key(.char("n")), [.redrawStatusBar])
    XCTAssertEqual(h.model.status.message?.text, "No search; / to search")
  }

  func testNoMatchesAndQuitFromTheField() {
    var h = Harness("Text")
    h.key(.char("/"))
    h.keys("zzz")
    XCTAssertEqual(h.model.status.message?.text, "No matches")
    XCTAssertFalse(h.key(.char("q")).contains(.quit), "q types into the field")
    XCTAssertEqual(h.model.findField, "zzzq")
    XCTAssertEqual(h.key(.ctrl("c")), [.quit])
  }

  func testCurrentMatchScrollsIntoViewIncludingInsideRegions() {
    var h = Harness(longDocument(paragraphs: 40) + "\n\n" + wideCode)
    h.key(.char("/"))
    h.keys("needle")
    h.key(.enter)
    let match = h.model.overlay.findMatches[0]
    let region = h.layout.regions.first { $0.maxOffset > 0 }!
    XCTAssertGreaterThan(region.offset, 0, "scrolled sideways to the match")
    let rect = try! XCTUnwrap(match.rects.first?.rect)
    XCTAssertTrue(region.rect.contains(CGPoint(x: rect.midX, y: rect.midY)))
    XCTAssertTrue(rect.minY >= h.model.offset && rect.maxY <= h.model.offset + 600)
  }

  func testNextMatchRedrawsBandsNotTheWholePage() {
    var h = Harness("one two one two one")
    h.key(.char("/"))
    h.keys("one")
    h.key(.enter)
    let effects = h.key(.char("n"))
    XCTAssertFalse(effects.redrawRects.isEmpty)
    XCTAssertFalse(effects.hasFullRedraw)
  }
}

final class LinkTests: XCTestCase {
  let guide = "[Jump](#target) [Other](other.md#part) [Web](https://example.com) [Gone](missing.md)\n\n"

  func document() -> String {
    guide + longDocument(paragraphs: 40) + "\n\n## Target\n\nEnd."
  }

  func testAnchorLinkScrollsAndBackReturns() {
    var h = Harness(document())
    h.click(h.point(of: "Jump"))
    let target = h.layout.anchorPosition("target")!.y
    XCTAssertEqual(h.model.offset, h.model.snapped(target))
    XCTAssertGreaterThan(h.model.offset, 0)
    h.key(.backspace)
    XCTAssertEqual(h.model.offset, 0)
    h.key(.char("L"))
    XCTAssertEqual(h.model.offset, h.model.snapped(target))
    h.key(.char("h"))
    XCTAssertEqual(h.model.offset, 0)
    h.key(.shiftBackspace)
    XCTAssertEqual(h.model.offset, h.model.snapped(target), "Shift-Backspace goes forward")
    XCTAssertEqual(h.key(.char("L")), [.redrawStatusBar])
    XCTAssertEqual(h.model.status.message?.text, "No next page")
  }

  func testMarkdownLinksLoadInPlaceWithHistory() {
    let other = longDocument(paragraphs: 40) + "\n\n## Part\n\nHere."
    var h = Harness(document(), files: ["/docs/other.md": other])
    let before = h.model.offset
    h.mouse(.motion, at: h.point(of: "Other"), button: 3)
    XCTAssertEqual(h.model.status.hint, "other.md#part", "hover shows the target")
    h.click(h.point(of: "Other"))
    XCTAssertEqual(h.loads.map(\.lastPathComponent), ["other.md"])
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    XCTAssertEqual(h.model.offset, h.model.snapped(h.layout.anchorPosition("part")!.y), "the fragment is followed")
    XCTAssertNil(h.model.status.hint)
    h.key(.backspace)
    XCTAssertEqual(h.model.file?.lastPathComponent, "guide.md")
    XCTAssertEqual(h.model.offset, before)
    h.key(.char("L"))
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
  }

  func testOpeningAnotherFileFromOutsideKeepsHistory() {
    var h = Harness(document(), files: ["/docs/other.md": "# Other"])
    h.key(.char("G"))
    let before = h.model.offset
    h.run(h.model.open(URL(fileURLWithPath: "/docs/other.md")))
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    XCTAssertEqual(h.model.offset, 0)
    XCTAssertEqual(h.model.open(URL(fileURLWithPath: "/docs/./other.md")), [.reload], "the shown file reloads")
    h.key(.backspace)
    XCTAssertEqual(h.model.file?.lastPathComponent, "guide.md")
    XCTAssertEqual(h.model.offset, before)
  }

  func testQuestionMarkShowsHelpAndAnyKeyClosesIt() {
    var h = Harness(document())
    XCTAssertEqual(h.key(.char("?")), [.redrawAll])
    XCTAssertTrue(h.model.helpVisible)
    let before = h.model.offset
    XCTAssertEqual(h.key(.char("G")), [.redrawAll], "the closing key does nothing else")
    XCTAssertFalse(h.model.helpVisible)
    XCTAssertEqual(h.model.offset, before)
  }

  func testAClickClosesHelpAndOtherMouseEventsAreIgnored() {
    var h = Harness(document())
    h.key(.char("?"))
    XCTAssertEqual(h.mouse(.motion, at: h.point(of: "Web"), button: 3), [])
    XCTAssertEqual(h.mouse(.wheelDown, at: h.point(of: "Web")), [])
    XCTAssertTrue(h.model.helpVisible)
    XCTAssertEqual(h.mouse(.press, at: h.point(of: "Web")), [.redrawAll])
    XCTAssertFalse(h.model.helpVisible)
    XCTAssertTrue(h.system.opened.isEmpty, "the closing click does not follow the link")
  }

  func testCommandFOpensFind() {
    var h = Harness(document())
    h.key(.command("f"))
    XCTAssertEqual(h.model.findField, "")
    h.keys("Web")
    XCTAssertEqual(h.key(.command("f")), [], "Cmd-F inside the field changes nothing")
    XCTAssertEqual(h.model.findField, "Web")
    h.key(.char("?"))
    XCTAssertEqual(h.model.findField, "Web?", "? types into the field")
  }

  func testFailedLoadKeepsHistoryIntact() {
    var h = Harness(document(), files: ["/docs/other.md": "# Other"])
    h.click(h.point(of: "Other"))
    h.system.files["/docs/guide.md"] = nil
    h.key(.backspace)
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    XCTAssertEqual(h.model.status.message?.kind, .error)
    h.system.files["/docs/guide.md"] = document()
    h.key(.backspace)
    XCTAssertEqual(h.model.file?.lastPathComponent, "guide.md", "the entry was restored after the failure")
  }

  func testExternalLinksUseTheInjectedOpener() {
    var h = Harness(document())
    h.click(h.point(of: "Web"))
    XCTAssertEqual(h.system.opened, [URL(string: "https://example.com")!])
    h.system.openSucceeds = false
    h.click(h.point(of: "Web"))
    XCTAssertEqual(h.model.status.message?.text, "Could not open https://example.com")
    h.click(h.point(of: "Gone"))
    XCTAssertEqual(h.model.status.message?.text, "Cannot open missing.md")
  }

  func testUnsafeLocalFilesAreRefused() {
    var h = Harness("[script](run.sh)", files: ["/docs/run.sh": "echo"])
    h.system.safeLocal = false
    h.click(h.point(of: "script"))
    XCTAssertTrue(h.system.opened.isEmpty)
    XCTAssertEqual(h.model.status.message?.text, "Not opening run.sh")
    h.system.safeLocal = true
    h.click(h.point(of: "script"))
    XCTAssertEqual(h.system.opened.map(\.lastPathComponent), ["run.sh"])
  }

  func testTabAndEnterFollowALink() {
    var h = Harness(document())
    h.key(.tab)
    XCTAssertEqual(h.model.status.hint, "#target")
    h.key(.enter)
    XCTAssertGreaterThan(h.model.offset, 0)
  }

  func testAnchorInsideCollapsedDetailsExpandsIt() {
    var h = Harness(
      "[Deep](#inner)\n\n" + longDocument(paragraphs: 30)
        + "\n\n<details><summary>Hidden</summary>\n\n### Inner\n\nText.\n\n</details>")
    let details = h.layout.targets.compactMap { area -> BlockID? in
      if case .detailsToggle(let id) = area.target { return id }
      return nil
    }.first!
    XCTAssertFalse(h.layout.expandedDetails.contains(details))
    h.click(h.point(of: "Deep"))
    XCTAssertTrue(h.layout.expandedDetails.contains(details))
    XCTAssertEqual(h.model.offset, h.model.snapped(h.layout.anchorPosition("inner")!.y))
  }

  func testDragFromALinkSelectsInsteadOfFollowing() {
    var h = Harness(document())
    h.mouse(.press, at: h.point(of: "Jump", at: 0))
    h.mouse(.motion, at: h.point(of: "Other", at: 1))
    h.mouse(.release, at: h.point(of: "Other", at: 1))
    XCTAssertEqual(h.model.offset, 0)
    XCTAssertNotNil(h.model.selection)
  }
}

final class DocumentStateTests: XCTestCase {
  func detailsDocument() -> String {
    longDocument(paragraphs: 30) + "\n\n<details><summary>Toggle me</summary>\n\n" + longDocument(paragraphs: 5)
      + "\n\n</details>\n\nAfter the details."
  }

  func testDetailsToggleKeepsTheSummaryInPlace() {
    var h = Harness(detailsDocument())
    let summary = h.point(of: "Toggle me")
    h.run(h.model.setOffset(summary.y - 200))
    let screenY = h.point(of: "Toggle me").y - h.model.offset
    h.click(h.point(of: "Toggle me"))
    XCTAssertEqual(h.layout.expandedDetails.count, 1)
    XCTAssertEqual(h.point(of: "Toggle me").y - h.model.offset, screenY, accuracy: 30)
    XCTAssertNotNil(h.range(of: "Paragraph 3 ", occurrence: 1).flatMap { h.layout.rects(for: $0).first })
    h.click(h.point(of: "Toggle me"))
    XCTAssertTrue(h.layout.expandedDetails.isEmpty)
    XCTAssertEqual(h.point(of: "Toggle me").y - h.model.offset, screenY, accuracy: 30)
    h.key(.tab)
    XCTAssertEqual(h.model.focus.map { if case .details = $0 { true } else { false } }, true)
    h.key(.enter)
    XCTAssertEqual(h.layout.expandedDetails.count, 1)
  }

  func testTaskBoxesAreReadOnly() {
    var h = Harness("- [ ] open task\n- [x] done task")
    let box = h.layout.targets.first { if case .task = $0.target { true } else { false } }!
    let effects = h.click(CGPoint(x: box.rect.midX, y: box.rect.midY))
    XCTAssertTrue(effects.layoutRequests.isEmpty)
    XCTAssertEqual(h.layout.targets.filter { if case .task = $0.target { true } else { false } }.count, 2)
    XCTAssertEqual(
      h.layout.decorations.filter { $0.kind == .taskBox(checked: true) }.count, 1, "nothing toggles")
  }

  func testZoomAnchorsTheTopContent() {
    var h = Harness(longDocument())
    h.run(h.model.setOffset(900))
    let top = h.model.topLine(in: h.layout)!.range.lowerBound
    let effects = h.key(.char("+"))
    XCTAssertEqual(effects.layoutRequests.first?.preparesAgain, true)
    XCTAssertEqual(h.model.zoom, 1.1)
    XCTAssertEqual(h.layout.prepared.typography.zoom, 1.1)
    XCTAssertEqual(h.model.status.message?.text, "Zoom 110%")
    let after = h.model.topLine(in: h.layout)!
    XCTAssertLessThan(abs(after.range.lowerBound - top), 80)
    h.key(.char("="))
    h.key(.char("-"))
    h.key(.char("-"))
    h.key(.char("-"))
    XCTAssertEqual(h.model.zoom, 0.9)
    h.key(.char("0"))
    XCTAssertEqual(h.model.zoom, 1)
    XCTAssertLessThan(abs(h.model.topLine(in: h.layout)!.range.lowerBound - top), 80)
    XCTAssertEqual(h.key(.char("0")), [])
  }

  func testReloadKeepsPositionSelectionAndFind() {
    let original = longDocument(paragraphs: 60)
    var h = Harness(original)
    h.run(h.model.setOffset(h.point(of: "Paragraph 40 ").y - 200))
    h.click(h.point(of: "Paragraph 40 "))
    h.click(h.point(of: "Paragraph 40 "), advance: 100_000_000)
    h.click(h.point(of: "Paragraph 40 "), advance: 100_000_000)
    let selected = h.layout.plainText(h.model.selection!)
    XCTAssertTrue(selected.hasPrefix("Paragraph 40 has"))
    h.key(.char("/"))
    h.keys("paragraph 5")
    h.key(.enter)
    let matchCount = h.model.overlay.findMatches.count
    let topParagraph = h.layout.plainText(h.layout.unitRange(at: h.model.topLine(in: h.layout)!.range.lowerBound))

    let edited = "# Inserted heading\n\nNew intro paragraph.\n\n" + original + "\n\nParagraph 59 extra."
    h.reload(edited)
    let newTop = h.layout.plainText(h.layout.unitRange(at: h.model.topLine(in: h.layout)!.range.lowerBound))
    XCTAssertEqual(newTop, topParagraph, "the same block stays at the top")
    XCTAssertEqual(h.layout.plainText(h.model.selection!), selected, "the selection moved with its text")
    XCTAssertEqual(h.model.findQuery, "paragraph 5")
    XCTAssertEqual(h.model.overlay.findMatches.count, matchCount + 1, "matches were recomputed")

    let removed = edited.replacingOccurrences(of: "Paragraph 40 has", with: "Paragraph forty has")
    h.reload(removed)
    XCTAssertNil(h.model.selection, "the selection is cleared when its text is gone")
  }

  func testAssetsChangedRelayoutsAndKeepsPosition() {
    var h = Harness(longDocument())
    h.run(h.model.setOffset(900))
    let offset = h.model.offset
    let effects = h.model.assetsChanged()
    XCTAssertEqual(effects.layoutRequests.first?.preparesAgain, false, "image sizes only need a new layout")
    h.run(effects)
    XCTAssertEqual(h.model.offset, offset)
  }

  func testStaleLayoutResultsAreIgnored() {
    var h = Harness(longDocument())
    let first = h.model.assetsChanged().layoutRequests[0]
    let second = h.model.assetsChanged().layoutRequests[0]
    XCTAssertEqual(h.model.apply(first.perform(), for: first), [])
    XCTAssertFalse(h.model.apply(second.perform(), for: second).isEmpty)
  }

  func testStatusBarShowsFileFolderProgressAndHint() {
    var h = Harness(longDocument(), path: "/tmp/notes/readme.md")
    var status = h.model.status
    XCTAssertEqual(status.fileName, "readme.md")
    XCTAssertEqual(status.folder, "/tmp/notes")
    XCTAssertEqual(status.progress.start, 0)
    XCTAssertEqual(status.progress.fraction, 600 / h.model.pageHeight, accuracy: 0.001)
    h.key(.char("G"))
    status = h.model.status
    XCTAssertEqual(status.progress.start + status.progress.fraction, 1, accuracy: 0.05)
  }
}

final class WorkerTests: XCTestCase {
  func testLayoutRunsOnAThreadWithAnExplicitStack() {
    let worker = LayoutWorker()
    XCTAssertGreaterThanOrEqual(worker.stackSize, 1024 * 1024)
    let depth = 100
    let markdown = String(repeating: "> ", count: depth) + "deep"
    let request = LayoutRequest(
      generation: 1, source: markdown, reuse: nil, typography: Typography(), width: 900, expandedDetails: nil,
      scrollOffsets: [:])
    let page = worker.perform { request.perform() }
    XCTAssertGreaterThan(page.fragments.count, 0)

    let done = expectation(description: "async layout")
    worker.layout(request, providers: LayoutProviders()) { page in
      XCTAssertGreaterThan(page.height, 0)
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    worker.stop()
    XCTAssertEqual(worker.perform { 7 }, 7, "a stopped worker runs inline")
  }
}

final class ChromeTests: XCTestCase {
  let palette = RenderPalette(
    colors: TerminalColorSet(foreground: RGB(hex: 0xdddddd), background: RGB(hex: 0x1e1e1e), colorScheme: .dark))

  func changedPixels(_ a: RasterBitmap, _ b: RasterBitmap, in rect: CGRect) -> Int {
    var count = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
      for x in Int(rect.minX)..<Int(rect.maxX) where a.pixel(x: x, y: y) != b.pixel(x: x, y: y) { count += 1 }
    }
    return count
  }

  func testFindFieldDrawsInTheStatusBar() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 1200, height: 44)
    let plain = try XCTUnwrap(RasterBitmap(width: 1200, height: 44))
    let field = try XCTUnwrap(RasterBitmap(width: 1200, height: 44))
    var content = StatusBarContent(fileName: "guide.md", progress: ScrollProgress(start: 0, fraction: 0.5))
    bar.draw(content, in: rect, bitmap: plain)
    content.findField = "needle"
    content.message = StatusMessage("1/3", kind: .find)
    bar.draw(content, in: rect, bitmap: field)
    XCTAssertGreaterThan(changedPixels(plain, field, in: CGRect(x: 600, y: 4, width: 600, height: 40)), 100)
    XCTAssertEqual(changedPixels(plain, field, in: CGRect(x: 0, y: 4, width: 200, height: 40)), 0, "the name stays")
  }

  func testRegionFocusRingIsDrawn() throws {
    let table =
      "| " + (1...30).map { "column\($0)" }.joined(separator: " | ") + " |\n|"
      + String(repeating: "---|", count: 30)
    let page = PreparedDocument(markdown: table).layout(width: 800)
    let region = try XCTUnwrap(page.regions.first)
    let rasterizer = Rasterizer(layout: page, palette: palette)
    let area = region.rect.insetBy(dx: -10, dy: -10)
    let plain = try XCTUnwrap(rasterizer.render(area))
    let ringed = try XCTUnwrap(rasterizer.render(area, overlay: RenderOverlay(focus: .region(region.id))))
    XCTAssertGreaterThan(changedPixels(plain, ringed, in: CGRect(x: 0, y: 0, width: plain.width, height: 12)), 50)
  }
}
