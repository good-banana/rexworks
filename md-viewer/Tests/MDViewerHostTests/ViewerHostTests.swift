import AppKit
import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerDisplay
import MDViewerInteraction
import MDViewerLayout
import XCTest

@testable import MDViewerHost
@testable import MDViewerMermaid
@testable import MDViewerRender

@MainActor
final class ViewerHostTests: XCTestCase {
  private let document = """
    # Title

    A paragraph with [another page](other.md) and enough words to select.

    ```swift
    let value = 1
    ```
    """

  func testStartLaysOutBeforeTheFirstFrame() throws {
    let fixture = try HostFixture(document)
    let writes = fixture.output.joined
    XCTAssertTrue(writes.contains("a=t,f=32,s=1600,v=1400"), "one full frame covering the pane")
    XCTAssertEqual(fences(in: writes).count, 1)
    XCTAssertEqual(fixture.host.transport.viewport.pageHeight, fixture.host.interaction.pageHeight)
    XCTAssertGreaterThan(fixture.host.interaction.pageHeight, 0)
    XCTAssertTrue(fixture.host.source.rasterizer.layout == fixture.host.interaction.layout)
  }

  func testUnreadableFileShowsAnInPageMessageAndAStatusError() throws {
    let directory = try TestDirectory()
    let output = RecordingOutput()
    let services = HostServices(
      output: output, pasteboard: FakePasteboard(), stagers: (MemoryStager(), nil),
      environment: InteractionEnvironment(openURL: { _ in true }, copyOnSelect: { false }), watchesFiles: false)
    let host = ViewerHost(
      size: testPaneSize, theme: ResolvedTheme(colors: TerminalColorSet(), source: .terminalQuery),
      services: services)
    let missing = directory.url.appendingPathComponent("gone.md")
    host.start(file: missing, windowSize: testPaneSize)
    XCTAssertEqual(host.interaction.status.message?.kind, .error)
    XCTAssertEqual(host.interaction.status.message?.text, "Cannot read gone.md")
    XCTAssertTrue(host.interaction.source.contains("Cannot read this file."))
    XCTAssertTrue(host.interaction.source.contains(missing.path))
    XCTAssertTrue(output.joined.contains("a=t,"), "the message is drawn")
  }

  func testUnreadableDocumentFencesBackticksInThePath() {
    let text = ViewerHost.unreadableDocument(URL(fileURLWithPath: "/tmp/a``b.md"))
    XCTAssertTrue(text.contains("``` /tmp/a``b.md ```"))
  }

  func testCopiesGoToThePasteboardAndNeverToTheTerminal() throws {
    let fixture = try HostFixture(document)
    _ = fixture.output.take()
    fixture.host.receive(Array("\u{1b}[97;9u".utf8))
    fixture.host.receive(Array("y".utf8))
    fixture.host.receive(Array("Y".utf8))
    XCTAssertEqual(fixture.pasteboard.writes.map(\.markdown), [false, true])
    XCTAssertTrue(fixture.pasteboard.writes[0].text.contains("A paragraph with another page"))
    XCTAssertTrue(fixture.pasteboard.writes[1].text.contains("[another page](other.md)"))
    XCTAssertFalse(fixture.output.joined.contains("\u{1b}]52;"))
    XCTAssertEqual(fixture.host.interaction.status.message?.kind, .success)
    fixture.pasteboard.succeeds = false
    fixture.host.receive(Array("y".utf8))
    XCTAssertEqual(fixture.host.interaction.status.message?.text, "Could not copy to the clipboard")
  }

  func testSystemPasteboardWritesPlainTextAndMarkdown() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("md-viewer-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let writer = SystemPasteboard(pasteboard: pasteboard)
    XCTAssertTrue(writer.write("plain", markdown: false))
    XCTAssertEqual(pasteboard.string(forType: .string), "plain")
    XCTAssertNil(pasteboard.string(forType: SystemPasteboard.markdownType))
    XCTAssertTrue(writer.write("**md**", markdown: true))
    XCTAssertEqual(pasteboard.string(forType: .string), "**md**")
    XCTAssertEqual(pasteboard.string(forType: SystemPasteboard.markdownType), "**md**")
  }

  func testVideoWithoutAPosterGetsALocalFrameAndRemoteVideosAreNeverFetched() throws {
    let fixture = try HostFixture(
      "<video src=\"clip.mp4\"></video>\n\n<video src=\"https://example.com/remote.mp4\"></video>\n",
      posterFrame: { url in url.lastPathComponent == "clip.mp4" ? solidImage(width: 64, height: 48) : nil },
      fetchRemote: { url, completion in
        XCTFail("fetched \(url)")
        completion(nil)
      })
    try Data("not really a movie".utf8).write(to: fixture.directory.url.appendingPathComponent("clip.mp4"))
    fixture.host.fileChanged()
    spin(until: {
      fixture.host.interaction.layout?.images.first?.hasIntrinsicSize == true
    })
    let boxes = try XCTUnwrap(fixture.host.interaction.layout?.images)
    XCTAssertEqual(boxes.map(\.video), ["clip.mp4", "https://example.com/remote.mp4"])
    XCTAssertTrue(boxes[0].hasIntrinsicSize, "the poster frame's size was laid out")
    XCTAssertFalse(boxes[1].hasIntrinsicSize)
  }

  func testControlSocketOpenKeepsHistory() throws {
    let fixture = try HostFixture(document, files: ["other.md": "# Other"])
    fixture.host.open(fixture.directory.url.appendingPathComponent("other.md"))
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "other.md")
    fixture.host.receive([0x7f])
    spin(until: { fixture.host.interaction.file?.lastPathComponent == "main.md" })
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "main.md")
  }

  func testLinksLoadInPlaceAndFailuresShowInTheStatusBar() throws {
    let fixture = try HostFixture(document)
    fixture.host.receive(Array("\t\r".utf8))
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "main.md")
    XCTAssertEqual(fixture.host.interaction.status.message?.text, "Cannot open other.md")
    try fixture.directory.write("other.md", "# Other")
    fixture.host.receive(Array("\r".utf8))
    spin(until: { fixture.host.interaction.file?.lastPathComponent == "other.md" })
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "other.md")
  }

  func testFileChangeReloadsAndAnUnreadableFileKeepsTheContent() throws {
    let fixture = try HostFixture(document)
    try fixture.directory.write("main.md", document + "\n\nAppended line.")
    fixture.host.fileChanged()
    spin(until: { fixture.host.interaction.layout?.prepared.source.contains("Appended") == true })
    XCTAssertTrue(fixture.host.source.rasterizer.layout.prepared.source.contains("Appended line."))
    try FileManager.default.removeItem(at: fixture.file)
    fixture.host.fileChanged()
    XCTAssertEqual(fixture.host.interaction.status.message?.text, "Cannot read main.md")
    XCTAssertTrue(fixture.host.interaction.source.contains("Appended line."))
  }

  func testWithoutInBandReportsTheWindowSizeUsesTheCellSizeQuery() throws {
    let fixture = try HostFixture(document)
    fixture.acknowledgeFrames()
    _ = fixture.output.take()
    fixture.host.windowChanged(PaneSize(columns: 120, rows: 40, pixelWidth: 1930, pixelHeight: 1410))
    XCTAssertTrue(fixture.output.joined.contains(TerminalSequences.queryCellSize))
    fixture.host.receive(Array("\u{1b}[6;35;16t".utf8))
    spin(until: { fixture.host.transport.viewport.size.columns == 120 }, timeout: 1)
    XCTAssertEqual(fixture.host.transport.viewport.size.pixelWidth, 1920, "ioctl columns times the cell width")
  }

  func testInBandReportsReplaceTheWindowSizeAndRelayoutBeforeTheSwap() throws {
    let fixture = try HostFixture(document)
    fixture.acknowledgeFrames()
    fixture.host.receive(Array("\u{1b}[?2048;2$y".utf8))
    _ = fixture.output.take()
    fixture.host.windowChanged(PaneSize(columns: 50, rows: 40, pixelWidth: 810, pixelHeight: 1410))
    XCTAssertFalse(fixture.output.joined.contains(TerminalSequences.queryCellSize))
    XCTAssertEqual(fixture.host.transport.viewport.size, testPaneSize, "SIGWINCH is only a wake-up")
    fixture.host.receive(Array("\u{1b}[48;40;50;1400;800t".utf8))
    XCTAssertTrue(fixture.host.transport.isHolding)
    spin(until: { !fixture.host.transport.isHolding && fixture.output.joined.contains("s=800,v=1400") })
    XCTAssertEqual(fixture.host.transport.viewport.size.pixelWidth, 800)
    XCTAssertEqual(fixture.host.source.rasterizer.layout.width, 800, "the frame was drawn from the new layout")
    XCTAssertEqual(fixture.host.interaction.geometry.width, 800)
  }

  func testGraphicsRepliesSettleFramesThroughTheDriver() throws {
    let fixture = try HostFixture(document)
    XCTAssertEqual(fixture.host.transport.outstandingFrames, 1)
    fixture.acknowledgeFrames()
    XCTAssertEqual(fixture.host.transport.outstandingFrames, 0)
  }

  func testColorSchemeNotificationRequeriesAndAppliesTheNewTheme() throws {
    let light = ResolvedTheme(colors: RenderPalette.fallbackColors(dark: false), source: .terminalQuery)
    let fixture = try HostFixture(document, resolve: { _ in light })
    fixture.acknowledgeFrames()
    _ = fixture.output.take()
    fixture.host.receive(Array("\u{1b}[?997;2n".utf8))
    spin(until: { fixture.output.joined.contains(TerminalColorQuery.colorSchemeQuery) }, timeout: 1)
    let query = fixture.output.take().joined()
    XCTAssertTrue(query.contains("\u{1b}]11;?"))
    XCTAssertTrue(query.hasSuffix(TerminalColorQuery.primaryDeviceAttributes))
    fixture.host.receive(Array("\u{1b}]11;rgb:ffff/ffff/ffff\u{1b}\\\u{1b}[?997;2n\u{1b}[?62;22c".utf8))
    spin(until: { fixture.host.palette == light.palette }, timeout: 2)
    XCTAssertEqual(fixture.host.source.rasterizer.palette, light.palette)
    XCTAssertEqual(fixture.themeCalls.colors.last?.background?.description, "#ffffff")
    spin(0.3)
    XCTAssertEqual(fixture.themeCalls.colors.count, 1, "the reply to our own 996 query is not a notification")
  }

  func testReloadKeyReresolvesTheTheme() throws {
    let fixture = try HostFixture(document)
    _ = fixture.output.take()
    fixture.host.receive(Array("r".utf8))
    spin(until: { fixture.output.joined.contains(TerminalColorQuery.primaryDeviceAttributes) }, timeout: 1)
    fixture.host.receive(Array("\u{1b}[?62;22c".utf8))
    spin(until: { fixture.themeCalls.colors.count == 1 }, timeout: 2)
    XCTAssertEqual(fixture.themeCalls.colors.count, 1)
  }

  func testStartupTimeoutIgnoresLateSchemeRepliesUntilTheLateDeviceAttributes() throws {
    let directory = try TestDirectory()
    let file = try directory.write("main.md", "# Hi")
    let output = RecordingOutput()
    let services = HostServices(
      output: output, pasteboard: FakePasteboard(), stagers: (MemoryStager(), nil),
      environment: InteractionEnvironment(openURL: { _ in true }, copyOnSelect: { false }), watchesFiles: false)
    let host = ViewerHost(
      size: testPaneSize, theme: ResolvedTheme(colors: TerminalColorSet(), source: .terminalQuery),
      themeQueryTimedOut: true, services: services)
    host.start(file: file, windowSize: testPaneSize)
    _ = output.take()
    host.receive(Array("\u{1b}[?997;1n".utf8))
    spin(0.25)
    XCTAssertFalse(output.joined.contains(TerminalColorQuery.primaryDeviceAttributes))
    host.receive(Array("\u{1b}[?62;22c\u{1b}[?997;1n".utf8))
    spin(until: { output.joined.contains(TerminalColorQuery.primaryDeviceAttributes) }, timeout: 1)
    XCTAssertTrue(output.joined.contains(TerminalColorQuery.primaryDeviceAttributes))
  }

  func testTimedOutHighlightsAreRetriedNotStored() throws {
    let fixture = try HostFixture(document)
    let layout = try XCTUnwrap(fixture.host.interaction.layout)
    let (id, block) = try XCTUnwrap(layout.prepared.codeBlocks.first)
    fixture.host.highlightArrived(id, HighlightResult(outcome: .timedOut), code: block.code)
    XCTAssertNil(fixture.host.source.rasterizer.highlights[id])
    XCTAssertEqual(fixture.host.highlightAttempts[id], nil, "no highlighter, nothing to retry")
    fixture.host.highlightArrived(id, HighlightResult(outcome: .unsupportedLanguage), code: "other code")
    XCTAssertNil(fixture.host.source.rasterizer.highlights[id], "results for other code are dropped")
    fixture.host.highlightArrived(id, HighlightResult(outcome: .unsupportedLanguage), code: block.code)
    XCTAssertEqual(fixture.host.source.rasterizer.highlights[id]?.outcome, .unsupportedLanguage)
  }

  func testHighlighterTimeoutsScheduleRetries() throws {
    var configuration = SyntaxHighlighter.Configuration()
    configuration.timeout = 0.000_001
    let directory = try TestDirectory()
    let file = try directory.write("main.md", document)
    let services = HostServices(
      output: RecordingOutput(), pasteboard: FakePasteboard(), stagers: (MemoryStager(), nil),
      environment: InteractionEnvironment(openURL: { _ in true }, copyOnSelect: { false }),
      highlighter: SyntaxHighlighter(configuration: configuration), watchesFiles: false)
    let host = ViewerHost(
      size: testPaneSize, theme: ResolvedTheme(colors: TerminalColorSet(), source: .terminalQuery),
      services: services)
    host.start(file: file, windowSize: testPaneSize)
    spin(until: { !host.highlightAttempts.isEmpty }, timeout: 3)
    XCTAssertEqual(host.highlightAttempts.values.first, 1)
    XCTAssertTrue(host.source.rasterizer.highlights.isEmpty)
  }

  func testCancelledDiagramsDrawNothingAndAreRequestedAgain() throws {
    let directory = try TestDirectory()
    let file = try directory.write("main.md", "# D\n\n```mermaid\ngraph TD; A-->B;\n```\n")
    let services = HostServices(
      output: RecordingOutput(), pasteboard: FakePasteboard(), stagers: (MemoryStager(), nil),
      environment: InteractionEnvironment(openURL: { _ in true }, copyOnSelect: { false }),
      mermaid: MermaidRenderer(pageURL: nil), watchesFiles: false)
    let host = ViewerHost(
      size: testPaneSize, theme: ResolvedTheme(colors: TerminalColorSet(), source: .terminalQuery),
      services: services)
    host.start(file: file, windowSize: testPaneSize)
    let layout = try XCTUnwrap(host.interaction.layout)
    let request = host.diagramContext(for: layout).request("graph TD; A-->B;\n")
    host.diagramsInFlight = [request.key]
    let rasterizer = host.source.rasterizer.index
    host.diagramArrived(request, MermaidDiagram.cancelled)
    XCTAssertTrue(host.diagramsInFlight.contains(request.key), "the still-wanted diagram was requested again")
    XCTAssertTrue(host.source.rasterizer.index === rasterizer, "nothing was redrawn for the cancellation")
    XCTAssertFalse(host.assetsPending)
    host.shutdown()
  }

  func testRegionScrollKeepsTheRasterizer() throws {
    let wide = "```\n" + String(repeating: "wide ", count: 200) + "\n```\n"
    let fixture = try HostFixture(wide)
    let before = fixture.host.source.rasterizer.index
    fixture.host.receive(Array("\t".utf8))
    fixture.host.receive(Array("l".utf8))
    let region = try XCTUnwrap(fixture.host.interaction.layout?.regions.first)
    XCTAssertGreaterThan(fixture.host.source.rasterizer.layout.offset(of: region.id), 0)
    XCTAssertTrue(fixture.host.source.rasterizer.index === before)
  }

  func testImagesCreatedOrChangedOnDiskAppearAfterAReload() throws {
    let fixture = try HostFixture("![pic](pic.png)\n")
    XCTAssertFalse(fixture.host.interaction.layout?.images.first?.hasIntrinsicSize ?? true)
    spin(0.2)
    let picture = fixture.directory.url.appendingPathComponent("pic.png")
    try pngData(width: 40, height: 20).write(to: picture)
    fixture.host.fileChanged()
    spin(until: { fixture.host.interaction.layout?.images.first?.hasIntrinsicSize == true })
    let first = try XCTUnwrap(fixture.host.interaction.layout?.images.first)
    try pngData(width: 80, height: 20).write(to: picture)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: picture.path)
    fixture.host.receive(Array("r".utf8))
    spin(until: { (fixture.host.interaction.layout?.images.first?.rect.width ?? 0) > first.rect.width })
    XCTAssertEqual(fixture.host.interaction.layout?.images.first?.rect.width, first.rect.width * 2)
  }

  func testFindCommitsWithEveryEnterEncodingThenNMovesToTheNextMatch() throws {
    let text = (1...12).map { "Paragraph \($0) mentions the index once." }.joined(separator: "\n\n")
    for enter in ["\r", "\u{1b}[13u", "\u{1b}[57414u", "\u{1b}OM"] {
      let fixture = try HostFixture(text)
      fixture.host.receive(Array("/".utf8))
      for character in "index" { fixture.host.receive(Array(String(character).utf8)) }
      fixture.host.receive(Array(enter.utf8))
      XCTAssertNil(fixture.host.interaction.findField, "Enter \(enter.debugDescription) commits the field")
      fixture.host.receive(Array("n".utf8))
      XCTAssertEqual(fixture.host.interaction.findQuery, "index")
      XCTAssertEqual(fixture.host.interaction.status.message?.text, "2/12", "Enter \(enter.debugDescription)")
      XCTAssertEqual(fixture.host.source.overlay.currentMatch, 1)
      XCTAssertEqual(fixture.host.source.overlay.findMatches.count, 12, "the highlights reach the frame source")
    }
  }

  func testTheFindFieldShowsOnlyWhileTyping() throws {
    let fixture = try HostFixture(document + "\n\nAnother paragraph with words.")
    XCTAssertNil(fixture.host.source.status?.findField, "hidden by default")
    fixture.host.receive(Array("/".utf8))
    XCTAssertEqual(fixture.host.source.status?.findField, "")
    for character in "para" { fixture.host.receive(Array(String(character).utf8)) }
    XCTAssertEqual(fixture.host.source.status?.findField, "para")
    fixture.host.receive(Array("\r".utf8))
    XCTAssertNil(fixture.host.source.status?.findField, "hidden after Enter")
    XCTAssertEqual(fixture.host.source.status?.message?.text, "1/2", "the matches stay active")
    fixture.host.receive(Array("n".utf8))
    XCTAssertEqual(fixture.host.source.status?.message?.text, "2/2")
    XCTAssertNil(fixture.host.source.status?.findField)
    fixture.host.receive(Array("\u{1b}[102;9u".utf8))
    XCTAssertEqual(fixture.host.source.status?.findField, "", "Cmd-F opens it again")
    fixture.host.receive(Array("\u{1b}[27u".utf8))
    XCTAssertNil(fixture.host.source.status?.findField, "hidden after Esc")
  }

  func testHelpReachesTheFrameSource() throws {
    let fixture = try HostFixture(document)
    fixture.host.receive(Array("?".utf8))
    XCTAssertTrue(fixture.host.source.showsHelp)
    fixture.host.receive(Array("x".utf8))
    XCTAssertFalse(fixture.host.source.showsHelp)
  }

  func testThemeMessagesReresolveTheTheme() throws {
    let fixture = try HostFixture(document)
    _ = fixture.output.take()
    fixture.host.themeChanged()
    spin(until: { fixture.output.joined.contains(TerminalColorQuery.primaryDeviceAttributes) }, timeout: 1)
    XCTAssertTrue(fixture.output.joined.contains(TerminalColorQuery.primaryDeviceAttributes))
  }

  func testStoppedDrawingIsReportedAsTextAndLogged() throws {
    let fixture = try HostFixture(document)
    _ = fixture.output.take()
    fixture.host.displayEvent(.failed("stopped drawing: the terminal is not answering"))
    XCTAssertEqual(
      fixture.output.joined,
      "\u{1b}[1;1H\u{1b}[2Kmd-viewer: stopped drawing: the terminal is not answering. Press a key to retry or q to quit."
    )
  }

  func testShutdownDeletesLiveImages() throws {
    let fixture = try HostFixture(document)
    fixture.acknowledgeFrames()
    _ = fixture.output.take()
    fixture.host.shutdown()
    XCTAssertTrue(fixture.output.joined.contains("a=d,d=I"))
  }
}

final class DiagramPlanTests: XCTestCase {
  func testVisibleDiagramsComeFirstThenDocumentOrder() {
    let markdown = (1...3).map {
      "```mermaid\ngraph TD; N\($0)-->M;\n```\n\n" + String(repeating: "Text.\n\n", count: 40)
    }
    .joined()
    let prepared = PreparedDocument(markdown: markdown, typography: Typography(backingScale: 2))
    let layout = prepared.layout(width: 1200)
    let third = layout.images.filter {
      if case .diagram = $0.content { return true } else { return false }
    }[2]
    let codes = DiagramPlan.codes(in: layout, visible: third.rect.insetBy(dx: 0, dy: -10))
    XCTAssertEqual(
      codes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
      [
        "graph TD; N3-->M;", "graph TD; N1-->M;", "graph TD; N2-->M;",
      ])
  }

  func testContextUsesTheColumnWidthInPoints() {
    let typography = Typography(bodySize: 15, zoom: 1.5, backingScale: 2)
    let palette = RenderPalette.fallback(dark: true)
    let context = DiagramContext(theme: MermaidTheme(palette: palette), pageWidth: 1600, typography: typography)
    XCTAssertEqual(context.scale, 3)
    XCTAssertEqual(context.width, (1600 - 2 * typography.pixels(em: typography.pageMarginSide)) / 3, accuracy: 0.001)
    XCTAssertEqual(context.request("a").width, context.width)
  }
}
