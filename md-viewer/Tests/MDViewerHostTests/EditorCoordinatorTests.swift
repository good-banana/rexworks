import Darwin
import Foundation
import MDViewerCore
import MDViewerInteraction
import XCTest

@testable import MDViewerHost

@MainActor
final class EditorCoordinatorTests: XCTestCase {
  func testQueueWorkRunsOffTheMainThread() throws {
    let fixture = try EditorFixture()
    fixture.launchNeovim()
    XCTAssertFalse(fixture.runner.calls.isEmpty)
    XCTAssertTrue(fixture.runner.calls.allSatisfy { !$0.onMainThread })
  }

  func testNeovimSplitLaunchArguments() throws {
    let fixture = try EditorFixture()
    fixture.press(line: 7)
    fixture.waitIdle()
    let paths = fixture.paths
    let run = try XCTUnwrap(fixture.runner.rexCalls.first { $0.first == "run" })
    let directory = fixture.file.deletingLastPathComponent().path
    let control = try XCTUnwrap(run.first { $0.hasPrefix("MD_VIEWER_CONTROL=") }).dropFirst(18)
    let id = URL(fileURLWithPath: String(control)).deletingPathExtension().lastPathComponent
    XCTAssertEqual(id.count, 16)
    XCTAssertEqual(
      run,
      [
        "run", "--json", "--session", EditorFixture.session, "--block", EditorFixture.previewBlock, "--split", "left",
        "--ratio", "50", "--label", "md-viewer-editor", "--cwd", directory, "--", "/usr/bin/env",
        "MD_VIEWER_SOCKET=\(fixture.home.url.appendingPathComponent("preview.sock").path)",
        "MD_VIEWER_TOKEN=token-1",
        "MD_VIEWER_CONTROL=\(paths.neovimControlSocket(id: id).path)",
        "MD_VIEWER_FILES=\(paths.neovimFiles(id: id).path)",
        "MD_VIEWER_BUFFERS=\(paths.buffersDirectory.path)",
        "MD_VIEWER_PLUGIN=\(paths.neovimPlugin.path)",
        "/fake/bin/nvim", "--cmd", "lua dofile(os.getenv('MD_VIEWER_PLUGIN'))", "-c", "lua MdViewer.ensure()", "+7",
        fixture.file.path,
      ])
    XCTAssertEqual(try String(contentsOf: paths.neovimPlugin, encoding: .utf8), NeovimPlugin.source)
    for directory in [paths.neovimSocketsDirectory, paths.buffersDirectory] {
      let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
      XCTAssertEqual(mode, 0o700, directory.lastPathComponent)
    }
    let entry = try XCTUnwrap(fixture.registry.entry(block: EditorFixture.launchedBlock))
    XCTAssertEqual(
      entry,
      EditorEntry(
        block: EditorFixture.launchedBlock, mode: .split, session: EditorFixture.session,
        files: [fixture.file.path], kind: .neovim, controlSocket: paths.neovimControlSocket(id: id).path,
        preview: EditorFixture.previewBlock))
    XCTAssertEqual(fixture.coordinator.link.block, EditorFixture.launchedBlock)
    XCTAssertEqual(fixture.coordinator.link.token, "token-1")
    XCTAssertEqual(fixture.coordinator.watchedBlocks, [EditorFixture.launchedBlock])
    XCTAssertEqual(
      fixture.waits.running(EditorFixture.launchedBlock)?.arguments,
      ["wait", EditorFixture.launchedBlock, "-s", EditorFixture.session, "--json"])
    XCTAssertEqual(fixture.status, "Opened Neovim")
    XCTAssertEqual(fixture.host.interaction.status.editor, "Neovim: live")
  }

  func testOtherTerminalEditorsLaunchWithoutATokenAndASecondEditorGoesBelowTheFirst() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other"], editor: "hx")
    fixture.runner.queueRun((0, runJSON(block: "block:helix"), Data()))
    fixture.press(line: 4)
    fixture.waitIdle()
    let first = try XCTUnwrap(fixture.runner.rexCalls.last { $0.first == "run" })
    XCTAssertEqual(Array(first.suffix(3)), ["--", "/fake/bin/hx", "\(fixture.file.path):4"])
    XCTAssertNil(fixture.coordinator.link.token)
    XCTAssertEqual(fixture.coordinator.link.block, "block:helix")
    XCTAssertEqual(fixture.host.interaction.status.editor, "Helix: on save")
    XCTAssertNil(fixture.registry.entry(block: "block:helix")?.controlSocket)

    fixture.host.open(fixture.hostFixture.directory.url.appendingPathComponent("other.md"))
    fixture.runner.queueRun((0, runJSON(block: "block:helix2"), Data()))
    fixture.press()
    fixture.waitIdle()
    let second = try XCTUnwrap(fixture.runner.rexCalls.last { $0.first == "run" })
    XCTAssertEqual(Array(second[4...7]), ["--block", "block:helix", "--split", "below"])
    XCTAssertEqual(fixture.registry.entries().map(\.block), ["block:helix", "block:helix2"])
  }

  func testTheBlockListFallbackFindsTheNewEditorPane() throws {
    let fixture = try EditorFixture(editor: "hx")
    try fixture.write(
      EditorEntry(block: "block:old", mode: .split, session: EditorFixture.session, files: ["/x.md"], kind: .helix))
    fixture.runner.queueRun((0, Data(#"{"block_ids":[]}"#.utf8), Data()))
    fixture.runner.reply(
      to: "block ls",
      (
        0,
        Data(
          #"{"blocks":[{"block_id":"block:old","label":"md-viewer-editor"},{"block_id":"block:new","label":"md-viewer-editor"}]}"#
            .utf8), Data()
      ))
    fixture.press()
    fixture.waitIdle()
    XCTAssertEqual(fixture.coordinator.link.block, "block:new")
    XCTAssertNotNil(fixture.registry.entry(block: "block:new"))
  }

  func testThePendingTokenIsRecordedBeforeRexRunAndBeforeLink() throws {
    let fixture = try EditorFixture()
    let coordinator = fixture.coordinator
    let seen = Recorder<String?>()
    fixture.runner.onRun = { _ in
      seen.add(DispatchQueue.main.sync { MainActor.assumeIsolated { coordinator.link.pending?.token } })
    }
    fixture.launchNeovim()
    XCTAssertEqual(seen.values, ["token-1"])

    fixture.control.onSend = { command in
      seen.add(DispatchQueue.main.sync { MainActor.assumeIsolated { coordinator.link.pending?.token } })
      if case .link(_, let token, _, _) = command { seen.add(token) }
    }
    fixture.press()
    fixture.waitIdle()
    XCTAssertEqual(seen.values, ["token-1", "token-2", "token-2"])
    XCTAssertEqual(coordinator.link.token, "token-2")
  }

  func testAnExistingNeovimGetsASingleLink() throws {
    let fixture = try EditorFixture()
    let entry = fixture.neovimEntry(block: "block:nvim", files: [fixture.file])
    try fixture.write(entry)
    fixture.press(line: 5)
    fixture.waitIdle()
    XCTAssertEqual(
      fixture.control.commands,
      [
        .link(
          socket: fixture.home.url.appendingPathComponent("preview.sock").path, token: "token-1",
          file: fixture.file.path, line: 5)
      ])
    XCTAssertEqual(fixture.control.sockets, [URL(fileURLWithPath: try XCTUnwrap(entry.controlSocket))])
    XCTAssertEqual(
      fixture.runner.rexCalls,
      [
        ["block", "inspect", "-s", EditorFixture.session, "block:nvim"],
        ["focus", "block:nvim", "-s", EditorFixture.session],
      ])
    XCTAssertEqual(fixture.registry.entry(block: "block:nvim")?.preview, EditorFixture.previewBlock)
    XCTAssertEqual(fixture.coordinator.link.block, "block:nvim")
    XCTAssertEqual(fixture.coordinator.link.token, "token-1")
    XCTAssertEqual(fixture.coordinator.watchedBlocks, ["block:nvim"])
    XCTAssertEqual(fixture.status, "Focused the editor")
  }

  func testAnExistingOtherEditorIsFocusedAndWatchedWithoutAToken() throws {
    let fixture = try EditorFixture(editor: "hx")
    try fixture.write(
      EditorEntry(
        block: "block:hx", mode: .split, session: EditorFixture.session, files: [fixture.file.path], kind: .helix))
    fixture.press(line: 9)
    fixture.waitIdle()
    XCTAssertEqual(
      fixture.runner.rexCalls,
      [
        ["block", "inspect", "-s", EditorFixture.session, "block:hx"],
        ["focus", "block:hx", "-s", EditorFixture.session],
      ])
    XCTAssertTrue(fixture.control.commands.isEmpty, "no line jump")
    XCTAssertEqual(fixture.coordinator.link.block, "block:hx")
    XCTAssertEqual(fixture.coordinator.link.kind, .helix)
    XCTAssertNil(fixture.coordinator.link.token)
    XCTAssertEqual(fixture.coordinator.watchedBlocks, ["block:hx"])
    XCTAssertEqual(fixture.status, "Focused the editor")
    XCTAssertEqual(fixture.host.interaction.status.editor, "Helix: on save")

    fixture.press()
    fixture.waitIdle()
    XCTAssertEqual(fixture.waits.processes.count, 1, "the existing watch is kept")
  }

  func testARelinkWhoseTokenWasDiscardedDoesNotClaimSuccess() throws {
    let fixture = try EditorFixture()
    try fixture.write(fixture.neovimEntry(block: "block:nvim", files: [fixture.file]))
    let host = fixture.host
    let file = fixture.file
    fixture.control.onSend = { command in
      guard case .link(_, let token, _, _) = command else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          host.receiveEditor(.unlinked(PluginEnvelope(token: token, seq: 1, file: file.path)))
        }
      }
    }
    fixture.press()
    fixture.waitIdle()
    XCTAssertEqual(fixture.control.commands.count, 1)
    XCTAssertNil(fixture.coordinator.link.block)
    XCTAssertNil(fixture.coordinator.link.pending)
    XCTAssertTrue(fixture.coordinator.watchedBlocks.isEmpty)
    XCTAssertNotEqual(fixture.status, "Focused the editor")
  }

  func testNeovimLiveSyncFailuresAreReportedAndTheLaunchProceeds() throws {
    let noSocket = try EditorFixture(previewSocket: false)
    noSocket.launchNeovim()
    XCTAssertEqual(noSocket.status, "Neovim live sync unavailable (no preview socket); refreshing on save")
    XCTAssertNil(noSocket.coordinator.link.token)
    XCTAssertEqual(noSocket.host.interaction.status.editor, "Neovim: on save")
    XCTAssertTrue(noSocket.logs.values.contains { $0.contains("no preview socket") })

    let long = try EditorFixture(homeSuffix: String(repeating: "h", count: 60))
    long.launchNeovim()
    XCTAssertEqual(long.status, "Neovim live sync unavailable (socket path too long); refreshing on save")
    XCTAssertEqual(
      long.runner.rexCalls.first { $0.first == "run" }?.suffix(3), ["/fake/bin/nvim", "+1", long.file.path])
    XCTAssertTrue(long.logs.values.contains { $0.contains("socket path too long") })

    let broken = try EditorFixture()
    try Data().write(to: broken.paths.root.appendingPathComponent("nvim"))
    broken.launchNeovim()
    XCTAssertEqual(broken.status, "Neovim live sync unavailable (plugin install failed); refreshing on save")
    XCTAssertNil(broken.coordinator.link.token)
    XCTAssertTrue(broken.logs.values.contains { $0.contains("plugin install failed") })
  }

  func testAFailedRegistryWriteAfterLaunchIsReported() throws {
    let fixture = try EditorFixture(editor: "hx")
    try Data().write(to: fixture.paths.editorsDirectory)
    fixture.runner.queueRun((0, runJSON(block: "block:helix"), Data()))
    fixture.press()
    fixture.waitIdle()
    XCTAssertEqual(fixture.status, "Could not record the editor; another e may open a second one")
    XCTAssertEqual(fixture.coordinator.link.block, "block:helix")
    XCTAssertTrue(fixture.logs.values.contains { $0.contains("could not write the entry for block:helix") })
  }

  func testAMissingEditorIsPrunedAndANewOneLaunched() throws {
    let fixture = try EditorFixture()
    try fixture.write(fixture.neovimEntry(block: "block:gone", files: [fixture.file]))
    fixture.runner.reply(
      to: "block inspect",
      (3, Data(), Data("Error: block target \"block:gone\" not found\n".utf8)))
    fixture.launchNeovim()
    XCTAssertNil(fixture.registry.entry(block: "block:gone"))
    XCTAssertNotNil(fixture.registry.entry(block: EditorFixture.launchedBlock))
  }

  func testHereIntentsRunTheRegistryCheck() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other"])
    try fixture.write(fixture.neovimEntry(block: "block:nvim", files: [fixture.file]))
    fixture.press(.alternate)
    fixture.waitIdle()
    XCTAssertTrue(fixture.handoffs.isEmpty)
    XCTAssertEqual(fixture.coordinator.link.block, "block:nvim")
    XCTAssertEqual(fixture.status, "Focused the editor")

    let other = fixture.hostFixture.directory.url.appendingPathComponent("other.md")
    try fixture.write(
      EditorEntry(block: "block:here", mode: .here, session: EditorFixture.session, files: [other.path], kind: .vim))
    fixture.host.open(other)
    fixture.press(.alternate)
    fixture.waitIdle()
    XCTAssertTrue(fixture.handoffs.isEmpty)
    XCTAssertEqual(fixture.runner.rexCalls.last, ["focus", "block:here", "-s", EditorFixture.session])
    XCTAssertEqual(fixture.status, "Already editing in another pane")
  }

  func testAnEditMessageInHereModeFocusesItsOwnPaneFirst() throws {
    let fixture = try EditorFixture()
    try SettingsStore.update(fixture.paths, set: [.editMode: "here"])
    fixture.host.receiveEditor(.edit(mode: .configured, line: 3))
    fixture.waitIdle()
    XCTAssertEqual(fixture.runner.rexCalls.first, ["focus", EditorFixture.previewBlock, "-s", EditorFixture.session])
    let launch = try XCTUnwrap(fixture.handoffs.first)
    XCTAssertEqual(launch.command.first, "/fake/bin/nvim")
    XCTAssertEqual(Array(launch.command.suffix(2)), ["+3", fixture.file.path])
    XCTAssertEqual(launch.environment["MD_VIEWER_TOKEN"], "token-1")
    XCTAssertEqual(launch.environment["PATH"], "/fake/bin")
    XCTAssertEqual(launch.block, EditorFixture.previewBlock)
    let entry = try XCTUnwrap(fixture.registry.entry(block: EditorFixture.previewBlock))
    XCTAssertEqual(entry.mode, .here)
    XCTAssertEqual(entry.controlSocket, launch.environment["MD_VIEWER_CONTROL"])
    XCTAssertEqual(fixture.coordinator.link.block, EditorFixture.previewBlock)
    XCTAssertEqual(fixture.coordinator.link.token, "token-1")
    XCTAssertTrue(fixture.coordinator.watchedBlocks.isEmpty)
  }

  func testAKeyInHereModeDoesNotFocus() throws {
    let fixture = try EditorFixture(editor: "hx")
    fixture.press(.alternate)
    fixture.waitIdle()
    XCTAssertTrue(fixture.runner.rexCalls.isEmpty)
    XCTAssertEqual(fixture.handoffs.map(\.command), [["/fake/bin/hx", "\(fixture.file.path):1"]])
    XCTAssertNil(fixture.handoffs.first?.token)
  }

  func testGUIEditorsLaunchThroughProcess() throws {
    let fixture = try EditorFixture(editor: "code")
    fixture.press(.alternate, line: 9)
    fixture.waitIdle()
    XCTAssertEqual(fixture.gui.launches.map(\.command), [["/fake/bin/code", "-g", "\(fixture.file.path):9"]])
    XCTAssertEqual(fixture.gui.launches.first?.environment, ["PATH": "/fake/bin", "LANG": "en_US.UTF-8"])
    XCTAssertTrue(fixture.handoffs.isEmpty)
    XCTAssertFalse(fixture.runner.rexCalls.contains { $0.first == "run" })
    XCTAssertEqual(fixture.status, "Opened VS Code")
  }

  func testTheProcessLauncherStartsTheCommandWithItsEnvironmentAndFolder() throws {
    let directory = try TestDirectory()
    try EditorCoordinator.launchProcess(
      EditorLaunch(
        command: ["/bin/sh", "-c", "printf %s \"$MARK\" > marked"], environment: ["MARK": "launched"],
        directory: directory.url, kind: .vscode))
    let marked = directory.url.appendingPathComponent("marked")
    spin(until: { (try? String(contentsOf: marked, encoding: .utf8)) == "launched" })
    XCTAssertEqual(try String(contentsOf: marked, encoding: .utf8), "launched")
  }

  func testOutsideRexEditsFallBackToHereMode() throws {
    let fixture = try EditorFixture(inRex: false)
    fixture.press()
    fixture.waitIdle()
    XCTAssertEqual(fixture.status, "Not in a Rex pane; editing here")
    XCTAssertEqual(fixture.handoffs.first?.command, ["/fake/bin/nvim", "+1", fixture.file.path])
    XCTAssertNil(fixture.handoffs.first?.token)
    XCTAssertTrue(fixture.runner.rexCalls.isEmpty)
    XCTAssertTrue(fixture.registry.entries().isEmpty)
  }

  func testAPressWhileBusyIsDropped() throws {
    let fixture = try EditorFixture()
    let gate = DispatchSemaphore(value: 0)
    fixture.runner.runGate = gate
    fixture.press()
    spin(until: { fixture.runner.rexCalls.contains { $0.first == "run" } })
    fixture.press()
    XCTAssertEqual(fixture.status, "Still opening the editor")
    gate.signal()
    fixture.waitIdle()
    XCTAssertEqual(fixture.runner.rexCalls.filter { $0.first == "run" }.count, 1)
    XCTAssertEqual(fixture.status, "Opened Neovim")
  }

  func testAPressIsAcceptedWhileAWatchRuns() throws {
    let fixture = try EditorFixture()
    fixture.launchNeovim()
    XCTAssertNotNil(fixture.waits.running(EditorFixture.launchedBlock))
    fixture.press(line: 2)
    fixture.waitIdle()
    XCTAssertEqual(fixture.control.commands.count, 1)
    XCTAssertEqual(fixture.status, "Focused the editor")
  }

  func testShutdownKillsTheWatches() throws {
    let fixture = try EditorFixture()
    fixture.launchNeovim()
    let watch = try XCTUnwrap(fixture.waits.running(EditorFixture.launchedBlock))
    fixture.host.shutdown()
    XCTAssertTrue(watch.stopped)
    XCTAssertTrue(fixture.coordinator.watchedBlocks.isEmpty)
    fixture.press()
    spin(0.1)
    XCTAssertEqual(fixture.runner.rexCalls.filter { $0.first == "run" }.count, 1)
  }

  func testRexWaitProcessReportsItsOutputAndStopsWhenAsked() throws {
    let directory = try TestDirectory()
    let script = directory.url.appendingPathComponent("rex")
    try Data("#!/bin/sh\nif [ \"$2\" = slow ]; then exec sleep 30; fi\necho '{\"exit_code\":0}'\n".utf8)
      .write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let output = Recorder<Data>()
    let quick = RexWaitProcess(executable: script.path, arguments: ["wait", "quick"]) { output.add($0) }
    XCTAssertNotNil(quick)
    spin(until: { !output.values.isEmpty })
    XCTAssertEqual(RexEditorPane.classifyWait(stdout: try XCTUnwrap(output.values.first)), .ended)

    let slow = try XCTUnwrap(RexWaitProcess(executable: script.path, arguments: ["wait", "slow"]) { output.add($0) })
    spin(0.1)
    slow.stop()
    spin(until: { kill(slow.processIdentifier, 0) != 0 })
    XCTAssertNotEqual(kill(slow.processIdentifier, 0), 0)
    spin(0.1)
    XCTAssertEqual(output.values.count, 1, "a stopped watch reports nothing")
  }

  func testWatchesWithoutAPayloadInspectTheBlockAndRetry() throws {
    let fixture = try EditorFixture()
    fixture.launchNeovim()
    let block = EditorFixture.launchedBlock
    fixture.coordinator.watches?.retryDelay = { _ in 0.01 }
    let first = try XCTUnwrap(fixture.waits.running(block))
    first.finished(Data())
    spin(until: { fixture.waits.processes.count == 2 })
    XCTAssertEqual(fixture.runner.rexCalls.last, ["block", "inspect", "-s", EditorFixture.session, block])
    XCTAssertEqual(fixture.coordinator.link.block, block)

    fixture.runner.reply(
      to: "block inspect", (3, Data(), Data("Error: block target \"\(block)\" not found".utf8)))
    try XCTUnwrap(fixture.waits.running(block)).finished(Data())
    spin(until: { fixture.coordinator.link.block == nil })
    XCTAssertEqual(fixture.status, "Editor closed")
    spin(until: { fixture.registry.entry(block: block) == nil })
    XCTAssertNil(fixture.registry.entry(block: block))
  }

  func testARetryForAStoppedWatchLeavesItsReplacementAlone() throws {
    let waits = FakeWaits()
    let watches = PaneWatches(session: EditorFixture.session, launch: waits.launcher)
    watches.retryDelay = { _ in 0.01 }
    var ended: Int?
    watches.onFinish = { _, generation, _ in ended = generation }
    watches.start("block:a")
    try XCTUnwrap(waits.running("block:a")).finished(Data())
    spin(until: { ended != nil })
    watches.stop("block:a")
    watches.start("block:a")
    let replacement = try XCTUnwrap(waits.running("block:a"))
    watches.retry("block:a", generation: try XCTUnwrap(ended))
    spin(0.1)
    XCTAssertEqual(waits.processes.count, 2)
    XCTAssertFalse(replacement.stopped)
    watches.stopAll()
    XCTAssertTrue(replacement.stopped)
  }

  func testThePickerOpensWhenNothingResolvesAndChoosingContinuesTheEdit() throws {
    let fixture = try EditorFixture(editor: nil)
    fixture.press(line: 2)
    fixture.waitIdle()
    let picker = try XCTUnwrap(fixture.host.interaction.editorPicker)
    XCTAssertEqual(
      picker.candidates.map(\.name),
      ["nvim", "hx", "vim", "emacs", "nano", "micro", "kak", "code", "cursor", "zed", "subl"])
    fixture.host.receive(Array("1".utf8))
    fixture.waitIdle()
    XCTAssertNil(fixture.host.interaction.editorPicker)
    let settings = SettingsStore.load(fixture.paths)
    XCTAssertEqual(settings.editor, "nvim")
    XCTAssertEqual(settings.editMode, .split)
    XCTAssertEqual(fixture.coordinator.link.block, EditorFixture.launchedBlock)
    XCTAssertEqual(fixture.runner.rexCalls.first { $0.first == "run" }?.suffix(2), ["+2", fixture.file.path])
  }

  func testAnUnresolvableSettingStopsWithItsMessage() throws {
    let fixture = try EditorFixture(editor: "/opt/nowhere/vi2 -u NONE")
    fixture.press()
    fixture.waitIdle()
    XCTAssertEqual(fixture.status, "editor setting: /opt/nowhere/vi2 not found; , to choose")
    XCTAssertTrue(fixture.runner.rexCalls.isEmpty)
  }

  func testTheLoginEnvironmentIsCachedUntilReload() throws {
    let fixture = try EditorFixture(editor: "code")
    let probes = { fixture.runner.calls.filter { $0.executable == "/bin/zsh" }.count }
    fixture.press()
    fixture.waitIdle()
    fixture.press()
    fixture.waitIdle()
    XCTAssertEqual(probes(), 1)
    fixture.host.receive(Array("r".utf8))
    fixture.press()
    fixture.waitIdle()
    XCTAssertEqual(probes(), 2)
  }

  func testJumpSendsTheCurrentToken() throws {
    let fixture = try EditorFixture()
    let token = fixture.launchNeovim()
    fixture.host.perform(.jumpEditor(line: 12))
    spin(until: { !fixture.control.commands.isEmpty })
    XCTAssertEqual(fixture.control.commands, [.jump(token: token, line: 12)])
  }

  func testLiveFollowsUpdateTheRegistryOnlyForOwnedTokens() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other"])
    let token = fixture.launchNeovim()
    let other = fixture.hostFixture.directory.url.appendingPathComponent("other.md")
    fixture.coordinator.liveFollow(token: "stranger", file: other.path)
    fixture.coordinator.liveFollow(token: token, file: other.path)
    spin(until: { fixture.registry.entry(block: EditorFixture.launchedBlock)?.files.count == 2 })
    XCTAssertEqual(
      fixture.registry.entry(block: EditorFixture.launchedBlock)?.files, [fixture.file.path, other.path])
  }
}

final class Recorder<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Value] = []

  var values: [Value] { lock.withLock { recorded } }

  func add(_ value: Value) { lock.withLock { recorded.append(value) } }
}
