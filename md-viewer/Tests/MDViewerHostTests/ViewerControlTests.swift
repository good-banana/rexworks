import Foundation
import MDViewerCore
import XCTest

@testable import MDViewerHost

@MainActor
final class ViewerControlTests: XCTestCase {
  private func socketPath() throws -> (directory: URL, socket: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(String(UUID().uuidString.prefix(8)))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, directory.appendingPathComponent("v.sock"))
  }

  func testTheSocketAnswersWhileTheFirstLayoutIsStillRunning() throws {
    let (directory, socket) = try socketPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = URL(fileURLWithPath: "/docs/requested.md")
    let control = ViewerControl()
    let server = try control.listen(
      on: socket, status: ViewerStatus(file: file, opener: "block:caller", openedAt: 3))
    defer { server.close() }
    let answered = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var probe = PreviewProbe.unreachable
    DispatchQueue.global().async {
      probe = ViewerSocketClient.query(socket)
      answered.signal()
    }
    XCTAssertEqual(answered.wait(timeout: .now() + 3), .success, "the main thread stays busy, as during layout")
    XCTAssertEqual(probe, .answered(ViewerState(file: file.path, openedAt: 3, opener: "block:caller")))
  }

  func testOpensAndThemeChangesDuringStartupAreAppliedOnceTheHostExists() throws {
    let (directory, socket) = try socketPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try HostFixture("# Main", files: ["other.md": "# Other"], start: false)
    let other = fixture.directory.url.appendingPathComponent("other.md")
    let status = ViewerStatus(file: fixture.file, opener: nil)
    let control = ViewerControl()
    let server = try control.listen(on: socket, status: status)
    defer { server.close() }
    XCTAssertTrue(ViewerSocketClient.send(path: other.path, to: socket))
    XCTAssertTrue(ViewerSocketClient.sendTheme(to: socket))
    spin(until: { control.pending.count == 2 })
    XCTAssertEqual(control.pending, [.open(other), .theme])

    var shown: [String] = []
    fixture.host.onDocumentShown = {
      status.show($0)
      shown.append($0.lastPathComponent)
    }
    fixture.host.start(file: fixture.file, windowSize: testPaneSize)
    _ = fixture.output.take()
    control.attach(fixture.host)
    XCTAssertEqual(shown, ["main.md", "other.md"])
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "other.md")
    XCTAssertEqual(status.state.file, other.path)
    XCTAssertTrue(control.pending.isEmpty)
    spin(until: { fixture.output.joined.contains(TerminalColorQuery.primaryDeviceAttributes) }, timeout: 1)
    XCTAssertTrue(
      fixture.output.joined.contains(TerminalColorQuery.primaryDeviceAttributes),
      "the queued theme change was requested")

    let third = try fixture.directory.write("third.md", "# Third")
    XCTAssertTrue(ViewerSocketClient.send(path: third.path, to: socket))
    spin(until: { fixture.host.interaction.file?.lastPathComponent == "third.md" })
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "third.md")
  }

  private func envelope(_ token: String, seq: Int = 1, file: String = "/docs/a.md") -> PluginEnvelope {
    PluginEnvelope(token: token, seq: seq, file: file)
  }

  func testEditorMessagesQueueBeforeAttachAndKeepOrderWithOpens() throws {
    let fixture = try HostFixture("# Main", files: ["other.md": "# Other"], start: false)
    let other = fixture.directory.url.appendingPathComponent("other.md")
    let control = ViewerControl()
    var log: [String] = []
    control.onEditorMessage = { log.append("editor:\(String(describing: $0))") }
    let edit = EditorMessage.edit(mode: .configured, line: 4)
    control.receive(editor: edit)
    control.open(other)
    control.themeChanged()
    control.themeChanged()
    XCTAssertEqual(control.pending, [.editor(edit), .open(other), .theme])
    XCTAssertTrue(log.isEmpty)

    fixture.host.start(file: fixture.file, windowSize: testPaneSize)
    control.attach(fixture.host)
    XCTAssertEqual(log, ["editor:\(edit)"])
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "other.md")
    XCTAssertTrue(control.pending.isEmpty)

    let follow = EditorMessage.follow(envelope("t"))
    control.receive(editor: follow)
    XCTAssertEqual(log.last, "editor:\(follow)")
  }

  func testLiveFollowUpdatesTheRegistryOnArrivalEvenWhenQueuedOrHeld() throws {
    let fixture = try HostFixture("# Main", start: false)
    let control = ViewerControl()
    var follows: [String] = []
    var delivered = 0
    control.onLiveFollow = { follows.append("\($0)|\($1)") }
    control.onEditorMessage = { _ in delivered += 1 }
    control.receive(editor: .follow(envelope("a", file: "/docs/one.md")))
    XCTAssertEqual(follows, ["a|/docs/one.md"])
    XCTAssertEqual(delivered, 0)

    fixture.host.start(file: fixture.file, windowSize: testPaneSize)
    control.attach(fixture.host)
    XCTAssertEqual(follows, ["a|/docs/one.md"], "replay never writes the registry")
    XCTAssertEqual(delivered, 1)

    control.beginHold(token: "h")
    control.receive(editor: .follow(envelope("h", seq: 2, file: "/docs/two.md")))
    control.receive(editor: .cursor(envelope("h", seq: 3), line: 2, top: 1, height: 10))
    control.receive(editor: .clean(envelope("h", seq: 4)))
    XCTAssertEqual(follows, ["a|/docs/one.md", "h|/docs/two.md"])
    XCTAssertEqual(delivered, 1, "held messages are not delivered")
    XCTAssertEqual(control.pending.count, 3)
  }

  func testHoldQueuesEverythingAndReleaseReplaysInOrder() throws {
    let fixture = try HostFixture("# Main", files: ["other.md": "# Other"], start: false)
    let other = fixture.directory.url.appendingPathComponent("other.md")
    fixture.host.start(file: fixture.file, windowSize: testPaneSize)
    let control = ViewerControl()
    var log: [EditorMessage] = []
    control.onEditorMessage = { log.append($0) }
    control.attach(fixture.host)
    XCTAssertFalse(control.isHolding)

    control.beginHold(token: "h")
    XCTAssertTrue(control.isHolding)
    let firstCursor = EditorMessage.cursor(envelope("h", seq: 1), line: 1, top: 1, height: 10)
    let lastCursor = EditorMessage.cursor(envelope("h", seq: 5), line: 9, top: 1, height: 10)
    let edit = EditorMessage.edit(mode: .alternate, line: 2)
    control.receive(editor: firstCursor)
    control.open(other)
    control.receive(editor: .exit(envelope("h", seq: 2)))
    control.receive(editor: edit)
    control.receive(editor: lastCursor)
    control.receive(editor: .cursor(envelope("stale", seq: 1), line: 3, top: 1, height: 10))
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "main.md")
    XCTAssertTrue(log.isEmpty)

    control.endHold()
    XCTAssertFalse(control.isHolding)
    XCTAssertEqual(log, [edit, lastCursor])
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "other.md")
    XCTAssertTrue(control.pending.isEmpty)
    control.endHold()
  }

  func testReplayKeepsOnlyTheLastHandoffCursorAndDropsOtherPluginMessages() {
    let other = URL(fileURLWithPath: "/docs/other.md")
    let cursor = { (token: String, seq: Int) in
      ViewerControlEvent.editor(
        .cursor(PluginEnvelope(token: token, seq: seq, file: "/a.md"), line: seq, top: 1, height: 5))
    }
    let plain = PluginEnvelope(token: "h", seq: 9, file: "/a.md")
    let edit = ViewerControlEvent.editor(.edit(mode: .configured, line: 1))
    let events: [ViewerControlEvent] = [
      cursor("h", 1), .open(other), .editor(.follow(plain)), cursor("x", 2), edit, cursor("h", 3), .theme,
      .editor(.buffer(plain, text: URL(fileURLWithPath: "/b/1.md"))), .editor(.clean(plain)),
      .editor(.unlinked(plain)), .editor(.exit(plain)),
    ]
    XCTAssertEqual(
      ViewerControl.replay(events, handoffToken: "h"), [.open(other), edit, cursor("h", 3), .theme])
    XCTAssertEqual(ViewerControl.replay([.editor(.follow(plain))], handoffToken: "other"), [])
    XCTAssertEqual(ViewerControl.replay([], handoffToken: "h"), [])
  }

  func testHoldBeforeAttachWaitsForReleaseThenFlushes() throws {
    let fixture = try HostFixture("# Main", files: ["other.md": "# Other"], start: false)
    let other = fixture.directory.url.appendingPathComponent("other.md")
    let control = ViewerControl()
    control.beginHold(token: "h")
    control.open(other)
    fixture.host.start(file: fixture.file, windowSize: testPaneSize)
    control.attach(fixture.host)
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "main.md")
    control.endHold()
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "other.md")
  }

  func testTheServerFeedsEditorMessagesThroughTheControl() throws {
    let (directory, socket) = try socketPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = ViewerControl()
    let server = try control.listen(on: socket, status: ViewerStatus(opener: nil))
    defer { server.close() }
    XCTAssertTrue(ViewerSocketClient.sendEdit(mode: .configured, line: 3, to: socket))
    XCTAssertTrue(ViewerSocketClient.sendEdit(mode: .alternate, line: 8, to: socket))
    spin(until: { control.pending.count == 2 })
    XCTAssertEqual(
      control.pending, [.editor(.edit(mode: .configured, line: 3)), .editor(.edit(mode: .alternate, line: 8))])
  }
}
