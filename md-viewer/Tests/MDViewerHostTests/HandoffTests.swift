import Foundation
import MDViewerCore
import MDViewerDisplay
import MDViewerInteraction
import XCTest

@testable import MDViewerHost

@MainActor
final class FakeHandoffTerminal: HandoffTerminal {
  struct SpawnFailure: Error {}

  var calls: [String] = []
  var pendingInput: [[UInt8]] = []
  var spawnFails = false
  var launches: [EditorLaunch] = []
  var onExit: (@MainActor (Int32) -> Void)?

  init(output: RecordingOutput) {
    output.onWrite = { [unowned self] text in
      let names = [
        TerminalSequences.restoreModes: "modes off", TerminalColorQuery.primaryDeviceAttributes: "sentinel",
        TerminalSequences.restoreScreen: "screen off",
        TerminalSequences.enter + TerminalSequences.enableViewerModes + TerminalSequences.queryInBandResizeReports:
          "viewer on",
      ]
      if let name = names[text] { calls.append(name) }
    }
  }

  var spawned: Bool { !launches.isEmpty }

  func setHandoffActive(_ active: Bool) { calls.append("handoff \(active)") }
  func suspendInput() { calls.append("suspend input") }
  func waitForInputQueue() { calls.append("sync input queue") }

  func readPendingInput() -> [UInt8] {
    calls.append("read")
    return pendingInput.isEmpty ? [] : pendingInput.removeFirst()
  }

  func leaveRawMode() { calls.append("leave raw") }

  func enterRawMode() -> Bool {
    calls.append("enter raw")
    return true
  }

  func resumeInput() { calls.append("resume input") }
  func size() -> PaneSize? { testPaneSize }

  func spawn(_ launch: EditorLaunch, onExit: @escaping @MainActor (Int32) -> Void) throws {
    calls.append("spawn")
    if spawnFails { throw SpawnFailure() }
    launches.append(launch)
    self.onExit = onExit
  }

  func exit(_ status: Int32) {
    onExit?(status)
  }
}

@MainActor
final class HandoffFixture {
  static let deviceAttributesReply = "\u{1b}[?62;22c"

  let editor: EditorFixture
  let control = ViewerControl()
  let terminal: FakeHandoffTerminal
  let controller: HandoffController
  var liveFollows: [String] = []

  init(
    _ markdown: String = "# Title\n\nBody text.\n", files: [String: String] = [:], editor name: String = "nvim",
    themeQueryTimedOut: Bool = false, drainTimeout: UInt64 = ViewerHost.handoffDrainTimeout
  ) throws {
    editor = try EditorFixture(markdown, files: files, editor: name, themeQueryTimedOut: themeQueryTimedOut)
    let host = editor.host
    let coordinator = editor.coordinator
    terminal = FakeHandoffTerminal(output: editor.hostFixture.output)
    controller = HandoffController(
      host: host, control: control, gate: editor.hostFixture.gate, terminal: terminal, drainTimeout: drainTimeout)
    control.onEditorMessage = { host.receiveEditor($0) }
    control.onLiveFollow = { [unowned self] token, file in
      liveFollows.append(file)
      coordinator.liveFollow(token: token, file: file)
    }
    control.attach(host)
    coordinator.onHandoff = { [unowned self] launch in
      self.editor.handoffs.append(launch)
      controller.start(launch)
    }
  }

  var host: ViewerHost { editor.host }
  var output: RecordingOutput { editor.hostFixture.output }
  var token: String { editor.handoffs.last?.token ?? "" }

  func pressHere(line: Int = 1) {
    editor.press(.alternate, line: line)
    spin(until: { self.host.handoffActive && !self.editor.coordinator.isBusy })
  }

  func reply(_ text: String) {
    host.receive(Array(text.utf8))
  }

  func runEditor() {
    pressHere()
    reply(Self.deviceAttributesReply)
    spin(until: { self.terminal.spawned })
  }

  func envelope(_ seq: Int, file: URL? = nil) -> PluginEnvelope {
    editor.envelope(token, seq, file: file)
  }
}

@MainActor
final class HandoffTests: XCTestCase {
  func testAHereEditQuietsTheViewerDrainsAndSpawnsInOrder() throws {
    let fixture = try HandoffFixture()
    fixture.terminal.pendingInput = [Array("late".utf8), Array("bytes".utf8)]
    fixture.pressHere()
    XCTAssertTrue(fixture.host.transport.isSuspended)
    XCTAssertFalse(fixture.editor.hostFixture.gate.isOpen)
    XCTAssertTrue(fixture.control.isHolding)
    XCTAssertFalse(fixture.terminal.spawned, "the drain waits for the sentinel reply")

    fixture.reply(HandoffFixture.deviceAttributesReply)
    spin(until: { fixture.terminal.spawned })
    XCTAssertEqual(
      fixture.terminal.calls,
      [
        "handoff true", "modes off", "sentinel", "suspend input", "sync input queue", "read", "read", "read",
        "screen off", "leave raw", "spawn",
      ])
    let launch = try XCTUnwrap(fixture.terminal.launches.first)
    XCTAssertEqual(launch.command.first, "/fake/bin/nvim")
    XCTAssertEqual(launch.environment["MD_VIEWER_TOKEN"], fixture.token)
  }

  func testTheGateBlocksOutputUntilResume() throws {
    let fixture = try HandoffFixture()
    fixture.runEditor()
    _ = fixture.output.take()
    fixture.host.services.output.write("probe")
    fixture.host.showEditorStatus("hidden", kind: .info)
    fixture.host.themeChanged()
    spin(0.3)
    XCTAssertEqual(fixture.output.writes, [])

    fixture.terminal.exit(0)
    XCTAssertTrue(fixture.editor.hostFixture.gate.isOpen)
    spin(until: { fixture.output.joined.contains("a=t,f=32") })
    XCTAssertTrue(fixture.output.joined.contains("a=t,f=32"), "resume sends a full frame")
  }

  func testResumeRestoresTheViewerModesBeforeTheDisplay() throws {
    let fixture = try HandoffFixture()
    fixture.runEditor()
    fixture.terminal.calls = []
    _ = fixture.output.take()
    fixture.terminal.exit(0)
    XCTAssertEqual(
      Array(fixture.terminal.calls.prefix(4)), ["enter raw", "viewer on", "resume input", "handoff false"])
    XCTAssertTrue(
      fixture.output.writes.first?.hasPrefix(TerminalSequences.enter + TerminalSequences.enableViewerModes) == true)
    XCTAssertFalse(fixture.host.handoffActive)
    XCTAssertFalse(fixture.host.transport.isSuspended)
  }

  func testASecondEditDuringTheHandoffIsIgnored() throws {
    let fixture = try HandoffFixture()
    fixture.pressHere()
    fixture.reply("E")
    fixture.reply(HandoffFixture.deviceAttributesReply)
    spin(until: { fixture.terminal.spawned })
    fixture.controller.start(try XCTUnwrap(fixture.editor.handoffs.first))
    spin(0.1)
    XCTAssertEqual(fixture.editor.handoffs.count, 1)
    XCTAssertEqual(fixture.terminal.launches.count, 1)
    XCTAssertFalse(fixture.editor.coordinator.isBusy)
  }

  func testATimedOutStartupQuerySeedsTheCounterAndEarlierRepliesAreDiscarded() throws {
    let fixture = try HandoffFixture(themeQueryTimedOut: true)
    XCTAssertEqual(fixture.host.pendingDeviceAttributes, 1)
    var quit = false
    fixture.host.onQuit = { quit = true }
    let offset = fixture.host.interaction.offset
    fixture.pressHere()
    XCTAssertEqual(fixture.host.pendingDeviceAttributes, 2)

    fixture.reply("q j \u{1b}[<0;5;5M\u{1b}]11;rgb:ffff/ffff/ffff\u{1b}\\")
    fixture.reply(HandoffFixture.deviceAttributesReply)
    spin(0.1)
    XCTAssertFalse(fixture.terminal.spawned, "the startup reply is not the sentinel")
    fixture.reply("j\u{1b}[?997;2n" + HandoffFixture.deviceAttributesReply)
    spin(until: { fixture.terminal.spawned })
    XCTAssertTrue(fixture.terminal.spawned)
    XCTAssertEqual(fixture.host.pendingDeviceAttributes, 0)
    XCTAssertFalse(quit)
    XCTAssertEqual(fixture.host.interaction.offset, offset)
    XCTAssertTrue(fixture.editor.hostFixture.themeCalls.colors.isEmpty)
  }

  func testALaterThemeQueryThatTimedOutIsCounted() throws {
    let fixture = try HandoffFixture()
    fixture.host.themeChanged()
    spin(until: { fixture.output.joined.contains(TerminalColorQuery.primaryDeviceAttributes) })
    XCTAssertEqual(fixture.host.pendingDeviceAttributes, 1)
    spin(until: { fixture.host.themeReplies == nil })
    fixture.pressHere()
    XCTAssertEqual(fixture.host.pendingDeviceAttributes, 2)
    fixture.reply(HandoffFixture.deviceAttributesReply)
    spin(0.1)
    XCTAssertFalse(fixture.terminal.spawned)
    fixture.reply(HandoffFixture.deviceAttributesReply)
    spin(until: { fixture.terminal.spawned })
    XCTAssertTrue(fixture.terminal.spawned)
  }

  func testAnInFlightThemeQueryIsAbandonedAndItsReplyCounted() throws {
    let fixture = try HandoffFixture()
    fixture.host.themeChanged()
    spin(until: { fixture.host.themeReplies != nil })
    fixture.pressHere()
    XCTAssertNil(fixture.host.themeReplies)
    XCTAssertFalse(fixture.host.themeScheduler.inFlight)
    fixture.reply("\u{1b}]11;rgb:ffff/ffff/ffff\u{1b}\\" + HandoffFixture.deviceAttributesReply)
    spin(0.1)
    XCTAssertFalse(fixture.terminal.spawned)
    fixture.reply(HandoffFixture.deviceAttributesReply)
    spin(until: { fixture.terminal.spawned })
    XCTAssertTrue(fixture.editor.hostFixture.themeCalls.colors.isEmpty)
  }

  func testAFenceWrittenJustBeforeTheEditDoesNotHoldTheDrain() throws {
    let fixture = try HandoffFixture()
    let pending = fences(in: fixture.output.joined)
    XCTAssertFalse(pending.isEmpty)
    XCTAssertEqual(fixture.host.transport.outstandingFrames, 1)
    fixture.pressHere()
    fixture.reply(HandoffFixture.deviceAttributesReply)
    spin(until: { fixture.terminal.spawned })
    XCTAssertTrue(fixture.terminal.spawned)
    for fence in pending { fixture.reply("\u{1b}_Gi=\(fence);OK\u{1b}\\") }
    XCTAssertEqual(fixture.host.transport.outstandingFrames, 0)
  }

  func testATimedOutDrainResetsTheCounterForTheNextHandoff() throws {
    let fixture = try HandoffFixture(themeQueryTimedOut: true, drainTimeout: 400_000_000)
    fixture.pressHere()
    XCTAssertEqual(fixture.host.pendingDeviceAttributes, 2)
    fixture.reply(HandoffFixture.deviceAttributesReply)
    spin(0.2)
    XCTAssertFalse(fixture.terminal.spawned)
    spin(until: { fixture.terminal.spawned }, timeout: 2)
    XCTAssertTrue(fixture.terminal.spawned, "the drain ends at its timeout")
    XCTAssertEqual(fixture.host.pendingDeviceAttributes, 0)
    fixture.terminal.exit(0)

    fixture.terminal.launches = []
    fixture.pressHere()
    XCTAssertEqual(fixture.host.pendingDeviceAttributes, 1)
    let replied = Date()
    fixture.reply(HandoffFixture.deviceAttributesReply)
    spin(until: { fixture.terminal.spawned })
    XCTAssertTrue(fixture.terminal.spawned)
    XCTAssertLessThan(Date().timeIntervalSince(replied), 0.3, "ended by the sentinel reply, not the timeout")
  }

  func testHeldMessagesQueueAndAFollowUpdatesTheRegistryAtOnce() throws {
    let fixture = try HandoffFixture(files: ["other.md": "# Other"])
    let other = fixture.editor.hostFixture.directory.url.appendingPathComponent("other.md")
    fixture.runEditor()
    fixture.control.receive(editor: .follow(fixture.envelope(1, file: other)))
    XCTAssertEqual(fixture.liveFollows, [other.path])
    spin(until: {
      fixture.editor.registry.entry(block: EditorFixture.previewBlock)?.files.contains(other.path) == true
    })
    XCTAssertEqual(
      fixture.editor.registry.entry(block: EditorFixture.previewBlock)?.files, [fixture.editor.file.path, other.path])
    XCTAssertEqual(fixture.control.pending.count, 1)
    XCTAssertEqual(fixture.host.interaction.file, fixture.editor.file)
  }

  func testResumeDropsPluginMessagesEndsLiveModeAndAppliesTheKeptCursor() throws {
    let markdown = (1...80).map { "Line \($0)\n" }.joined(separator: "\n")
    let fixture = try HandoffFixture(markdown, files: ["other.md": "# Other"])
    let other = fixture.editor.hostFixture.directory.url.appendingPathComponent("other.md")
    fixture.runEditor()
    let buffer = try fixture.editor.writeBuffer("# Unsaved\n")
    fixture.host.receiveEditor(.buffer(fixture.envelope(1), text: buffer))
    XCTAssertTrue(fixture.host.interaction.liveBuffer)

    fixture.control.receive(editor: .cursor(fixture.envelope(2), line: 20, top: 1, height: 10))
    fixture.control.receive(editor: .follow(fixture.envelope(3, file: other)))
    fixture.control.receive(editor: .clean(fixture.envelope(4)))
    fixture.control.receive(editor: .cursor(fixture.envelope(5), line: 120, top: 1, height: 10))
    fixture.control.receive(
      editor: .cursor(
        PluginEnvelope(token: "stale", seq: 6, file: fixture.editor.file.path), line: 3, top: 1, height: 10))
    fixture.control.receive(editor: .buffer(fixture.envelope(7), text: buffer))
    XCTAssertEqual(fixture.liveFollows, [other.path])

    fixture.terminal.exit(0)
    XCTAssertFalse(fixture.host.interaction.liveBuffer)
    XCTAssertEqual(fixture.host.interaction.file, fixture.editor.file)
    XCTAssertNil(fixture.editor.coordinator.link.token)
    XCTAssertNil(fixture.editor.coordinator.link.block)
    XCTAssertNil(fixture.editor.coordinator.link.pending)
    XCTAssertEqual(fixture.host.interaction.editorCursor?.line, 120)
    XCTAssertEqual(fixture.liveFollows, [other.path], "replay never writes the registry")
    XCTAssertTrue(fixture.control.pending.isEmpty)
    XCTAssertEqual(fixture.editor.status, "Back from nvim")
    XCTAssertNotNil(fixture.host.themeScheduler.dueAt, "the theme is re-queried")
    spin(until: { fixture.host.interaction.layout?.prepared.units.count ?? 0 > 10 })
    XCTAssertTrue(fixture.host.interaction.source.hasPrefix("Line 1"))
    spin(until: { fixture.editor.registry.entry(block: EditorFixture.previewBlock) == nil })
    XCTAssertNil(fixture.editor.registry.entry(block: EditorFixture.previewBlock))
  }

  func testAReplayedOpenSkipsTheKeptCursor() throws {
    let fixture = try HandoffFixture(files: ["other.md": "# Other"])
    let other = fixture.editor.hostFixture.directory.url.appendingPathComponent("other.md")
    fixture.runEditor()
    fixture.control.receive(editor: .cursor(fixture.envelope(1), line: 2, top: 1, height: 10))
    fixture.control.open(other)
    fixture.control.themeChanged()
    fixture.terminal.exit(0)
    XCTAssertEqual(fixture.host.interaction.file, other)
    XCTAssertNil(fixture.host.interaction.editorCursor)
  }

  func testExitStatusesAndSpawnFailuresAreReported() throws {
    let fixture = try HandoffFixture()
    fixture.runEditor()
    fixture.terminal.exit(3)
    XCTAssertEqual(fixture.editor.status, "nvim exited with status 3")
    XCTAssertEqual(fixture.host.interaction.status.message?.kind, .error)

    fixture.terminal.spawnFails = true
    fixture.terminal.launches = []
    fixture.pressHere()
    fixture.reply(HandoffFixture.deviceAttributesReply)
    spin(until: { !fixture.host.handoffActive })
    XCTAssertEqual(fixture.editor.status, "Could not open Neovim")
    XCTAssertTrue(fixture.editor.hostFixture.gate.isOpen)
    XCTAssertFalse(fixture.control.isHolding)
    XCTAssertNil(fixture.controller.launch)
  }

  func testOtherTerminalEditorsHandOffWithoutATokenAndRemoveTheirEntry() throws {
    let fixture = try HandoffFixture(editor: "hx")
    fixture.runEditor()
    XCTAssertNil(fixture.editor.handoffs.last?.token)
    XCTAssertNotNil(fixture.editor.registry.entry(block: EditorFixture.previewBlock))
    fixture.control.receive(
      editor: .cursor(PluginEnvelope(token: "x", seq: 1, file: fixture.editor.file.path), line: 2, top: 1, height: 10))
    fixture.terminal.exit(0)
    XCTAssertEqual(fixture.editor.status, "Back from hx")
    XCTAssertNil(fixture.host.interaction.editorCursor)
    spin(until: { fixture.editor.registry.entry(block: EditorFixture.previewBlock) == nil })
    XCTAssertNil(fixture.editor.registry.entry(block: EditorFixture.previewBlock))
  }

  func testWindowChangesAreIgnoredDuringTheHandoff() throws {
    let fixture = try HandoffFixture()
    fixture.runEditor()
    _ = fixture.output.take()
    fixture.host.windowChanged(PaneSize(columns: 50, rows: 20, pixelWidth: 800, pixelHeight: 700))
    XCTAssertEqual(fixture.host.transport.viewport.size, testPaneSize)
    XCTAssertEqual(fixture.output.writes, [])
  }
}
