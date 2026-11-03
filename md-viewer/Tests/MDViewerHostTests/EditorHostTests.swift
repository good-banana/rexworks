import Foundation
import MDViewerCore
import MDViewerInteraction
import XCTest

@testable import MDViewerHost

@MainActor
final class EditorHostTests: XCTestCase {
  private static func lines(_ count: Int, prefix: String = "Line") -> String {
    (1...count).map { "\(prefix) \($0) with enough words to make a paragraph." }.joined(separator: "\n\n") + "\n"
  }

  private func settled(_ fixture: EditorFixture) {
    spin(until: { fixture.host.interaction.pendingRequest == nil })
  }

  // MARK: Live buffer and cursor

  func testABufferRendersAndKeepsScroll() throws {
    let disk = Self.lines(80)
    let fixture = try EditorFixture(disk)
    let token = fixture.launchNeovim()
    fixture.host.receive(Array("\u{1b}[6~".utf8))
    settled(fixture)
    let offset = fixture.host.interaction.offset
    XCTAssertGreaterThan(offset, 0)
    let unsaved = disk + "\nUnsaved tail.\n"
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 1), text: try fixture.writeBuffer(unsaved)))
    settled(fixture)
    XCTAssertEqual(fixture.host.interaction.source, unsaved)
    XCTAssertTrue(fixture.host.interaction.liveBuffer)
    XCTAssertEqual(fixture.host.interaction.offset, offset, accuracy: 1)
    XCTAssertEqual(fixture.host.interaction.status.editor, "Neovim: unsaved")
  }

  func testBuffersOutsideTheBuffersDirectoryAreIgnored() throws {
    let fixture = try EditorFixture()
    let token = fixture.launchNeovim()
    let outside = try fixture.hostFixture.directory.write("sneaky.md", "# Sneaky")
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 1), text: outside))
    XCTAssertFalse(fixture.host.interaction.liveBuffer)
    XCTAssertFalse(fixture.host.interaction.source.contains("Sneaky"))
  }

  func testFileWatcherChangesAreIgnoredDuringALiveBufferAndTheMessageShowsOnce() throws {
    let fixture = try EditorFixture()
    let token = fixture.launchNeovim()
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 1), text: try fixture.writeBuffer("# Unsaved\n")))
    settled(fixture)
    try fixture.hostFixture.directory.write("main.md", "# Saved by someone else\n")
    fixture.host.fileChanged()
    fixture.host.fileChanged()
    XCTAssertNotEqual(fixture.status, ViewerHost.liveBufferNotice, "the editor's own save gets a grace period")
    spin(until: { fixture.status == ViewerHost.liveBufferNotice })
    XCTAssertEqual(fixture.host.interaction.source, "# Unsaved\n")
    XCTAssertEqual(fixture.status, "File changed on disk; showing the editor's unsaved text")
    fixture.host.showEditorStatus("Something else", kind: .info)
    fixture.host.fileChanged()
    spin(ViewerHost.editorSaveGrace + 0.2)
    XCTAssertEqual(fixture.status, "Something else")
    XCTAssertEqual(fixture.host.interaction.source, "# Unsaved\n")
  }

  func testTheEditorsOwnSaveFollowedByCleanShowsNoDiskChangeNotice() throws {
    let fixture = try EditorFixture()
    let token = fixture.launchNeovim()
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 1), text: try fixture.writeBuffer("# Unsaved\n")))
    settled(fixture)
    try fixture.hostFixture.directory.write("main.md", "# Unsaved and more\n")
    fixture.host.fileChanged()
    fixture.host.receiveEditor(.clean(fixture.envelope(token, 2)))
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 3), text: try fixture.writeBuffer("# Typing again\n")))
    spin(ViewerHost.editorSaveGrace + 0.2)
    XCTAssertNotEqual(fixture.status, ViewerHost.liveBufferNotice)
    XCTAssertEqual(fixture.host.interaction.source, "# Typing again\n")
  }

  func testAnExternalChangeInANewLiveSessionWarnsWhileTheOldSessionsCheckIsPending() throws {
    let fixture = try EditorFixture()
    let token = fixture.launchNeovim()
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 1), text: try fixture.writeBuffer("# Unsaved\n")))
    settled(fixture)
    try fixture.hostFixture.directory.write("main.md", "# Unsaved and saved\n")
    fixture.host.fileChanged()
    fixture.host.receiveEditor(.clean(fixture.envelope(token, 2)))
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 3), text: try fixture.writeBuffer("# Typing again\n")))
    settled(fixture)
    try fixture.hostFixture.directory.write("main.md", "# An agent's edit\n")
    fixture.host.fileChanged()

    var notices = 0
    var last = fixture.status
    let deadline = Date().addingTimeInterval(2 * ViewerHost.editorSaveGrace + 0.5)
    while Date() < deadline {
      spin(0.02)
      if fixture.status != last {
        if fixture.status == ViewerHost.liveBufferNotice { notices += 1 }
        last = fixture.status
      }
    }
    XCTAssertEqual(notices, 1)
    XCTAssertEqual(fixture.status, ViewerHost.liveBufferNotice)
    XCTAssertEqual(fixture.host.interaction.source, "# Typing again\n")
  }

  func testADiskChangeMatchingTheLiveTextShowsNoNoticeEvenBeforeClean() throws {
    let fixture = try EditorFixture()
    let token = fixture.launchNeovim()
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 1), text: try fixture.writeBuffer("# Unsaved\n")))
    settled(fixture)
    try fixture.hostFixture.directory.write("main.md", "# Unsaved\n")
    fixture.host.fileChanged()
    spin(ViewerHost.editorSaveGrace + 0.2)
    XCTAssertNotEqual(fixture.status, ViewerHost.liveBufferNotice)
    XCTAssertTrue(fixture.host.interaction.liveBuffer)

    try fixture.hostFixture.directory.write("main.md", "# An agent's edit\n")
    fixture.host.fileChanged()
    spin(until: { fixture.status == ViewerHost.liveBufferNotice })
    XCTAssertEqual(fixture.status, ViewerHost.liveBufferNotice)
    XCTAssertEqual(fixture.host.interaction.source, "# Unsaved\n")
  }

  func testCleanReloadsFromDisk() throws {
    let fixture = try EditorFixture()
    let token = fixture.launchNeovim()
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 1), text: try fixture.writeBuffer("# Unsaved\n")))
    try fixture.hostFixture.directory.write("main.md", "# Saved\n")
    fixture.host.receiveEditor(.clean(fixture.envelope(token, 2)))
    settled(fixture)
    XCTAssertEqual(fixture.host.interaction.source, "# Saved\n")
    XCTAssertFalse(fixture.host.interaction.liveBuffer)
    XCTAssertEqual(fixture.host.interaction.status.editor, "Neovim: live")
  }

  func testFollowLeavesLiveBufferModeAndAFollowingCleanShowsTheFileOnDisk() throws {
    let fixture = try EditorFixture()
    let token = fixture.launchNeovim()
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 1), text: try fixture.writeBuffer("# Unsaved\n")))
    fixture.host.receiveEditor(.cursor(fixture.envelope(token, 2), line: 1, top: 1, height: 20))
    fixture.host.receiveEditor(.follow(fixture.envelope(token, 3)))
    XCTAssertFalse(fixture.host.interaction.liveBuffer)
    XCTAssertNil(fixture.host.interaction.editorCursor)
    fixture.host.receiveEditor(.clean(fixture.envelope(token, 4)))
    settled(fixture)
    XCTAssertEqual(fixture.host.interaction.source, try String(contentsOf: fixture.file, encoding: .utf8))
    XCTAssertFalse(fixture.host.interaction.liveBuffer)
  }

  func testASocketOpenLeavesLiveBufferMode() throws {
    let fixture = try EditorFixture()
    let token = fixture.launchNeovim()
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 1), text: try fixture.writeBuffer("# Unsaved\n")))
    fixture.host.receiveEditor(.cursor(fixture.envelope(token, 2), line: 1, top: 1, height: 20))
    fixture.host.open(fixture.file)
    settled(fixture)
    XCTAssertFalse(fixture.host.interaction.liveBuffer)
    XCTAssertNil(fixture.host.interaction.editorCursor)
    XCTAssertEqual(fixture.host.interaction.source, try String(contentsOf: fixture.file, encoding: .utf8))
  }

  func testFollowToAnotherFileOpensIt() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other\n"])
    let token = fixture.launchNeovim()
    let other = fixture.hostFixture.directory.url.appendingPathComponent("other.md")
    fixture.host.receiveEditor(.follow(fixture.envelope(token, 1, file: other)))
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "other.md")
    XCTAssertTrue(fixture.host.interaction.editorLink?.followsShownFile == true)
    fixture.host.receiveEditor(.cursor(fixture.envelope(token, 2), line: 1, top: 1, height: 20))
    XCTAssertNil(fixture.host.interaction.editorCursor, "cursors for the old file are dropped")
  }

  func testACursorBeforeABufferAddingLinesAboveIsAppliedAgainAfterTheNewLayout() throws {
    let disk = Self.lines(60)
    let fixture = try EditorFixture(disk)
    let token = fixture.launchNeovim()
    fixture.host.receiveEditor(.cursor(fixture.envelope(token, 1), line: 41, top: 30, height: 20))
    let before = try XCTUnwrap(fixture.host.interaction.y(forSourceLine: 41))
    XCTAssertEqual(fixture.host.interaction.overlay.sourceCursor?.minY, before)
    let unsaved = "```\na\nb\nc\nd\ne\n```\n\n" + disk
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 2), text: try fixture.writeBuffer(unsaved)))
    settled(fixture)
    let after = try XCTUnwrap(fixture.host.interaction.y(forSourceLine: 41))
    XCTAssertNotEqual(after, before)
    XCTAssertEqual(fixture.host.interaction.overlay.sourceCursor?.minY, after)
  }

  // MARK: Links and tokens

  func testUnlinkedStopsTheWatchAndKeepsTheEntry() throws {
    let fixture = try EditorFixture()
    let token = fixture.launchNeovim()
    let watch = try XCTUnwrap(fixture.waits.running(EditorFixture.launchedBlock))
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 1), text: try fixture.writeBuffer("# Unsaved\n")))
    fixture.host.receiveEditor(.unlinked(fixture.envelope(token, 2)))
    XCTAssertTrue(watch.stopped)
    XCTAssertNil(fixture.coordinator.link.block)
    XCTAssertNil(fixture.host.interaction.editorLink)
    XCTAssertFalse(fixture.host.interaction.liveBuffer)
    settled(fixture)
    XCTAssertEqual(fixture.host.interaction.source, try String(contentsOf: fixture.file, encoding: .utf8))
    XCTAssertEqual(fixture.status, "Editor linked to another preview")
    spin(0.1)
    XCTAssertNotNil(fixture.registry.entry(block: EditorFixture.launchedBlock))
  }

  func testUnlinkedStillAppliesAfterNavigation() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other\n"])
    let other = fixture.hostFixture.directory.url.appendingPathComponent("other.md")
    let token = fixture.launchNeovim()
    fixture.host.open(other)
    fixture.host.receiveEditor(.unlinked(fixture.envelope(token, 1)))
    XCTAssertNil(fixture.coordinator.link.block)
    XCTAssertEqual(fixture.status, "Editor linked to another preview")
    fixture.host.receiveEditor(.follow(fixture.envelope(token, 2)))
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "other.md", "the old token is no longer heard")
  }

  func testExitStillAppliesAfterNavigation() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other\n"])
    let token = fixture.launchNeovim()
    fixture.host.open(fixture.hostFixture.directory.url.appendingPathComponent("other.md"))
    fixture.host.receiveEditor(.exit(fixture.envelope(token, 1)))
    XCTAssertNil(fixture.coordinator.link.block)
    XCTAssertEqual(fixture.status, "Editor closed")
    XCTAssertTrue(fixture.coordinator.watchedBlocks.isEmpty)
    spin(until: { fixture.registry.entry(block: EditorFixture.launchedBlock) == nil })
    XCTAssertNil(fixture.registry.entry(block: EditorFixture.launchedBlock))
  }

  func testRelinkingFromOneNeovimToAnotherDropsStaleTokens() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other\n"])
    let other = fixture.hostFixture.directory.url.appendingPathComponent("other.md")
    let first = fixture.launchNeovim(block: "block:nvim1")
    fixture.host.receiveEditor(.follow(fixture.envelope(first, 1)))
    fixture.host.receiveEditor(.cursor(fixture.envelope(first, 2), line: 1, top: 1, height: 20))
    fixture.host.receiveEditor(.cursor(fixture.envelope(first, 2), line: 3, top: 1, height: 20))
    XCTAssertEqual(fixture.host.interaction.editorCursor?.line, 1, "a repeated seq is dropped")

    try fixture.write(fixture.neovimEntry(block: "block:nvim2", files: [other]))
    fixture.host.open(other)
    fixture.press()
    fixture.waitIdle()
    let second = try XCTUnwrap(fixture.coordinator.link.pending?.token)
    XCTAssertNotEqual(second, first)
    XCTAssertEqual(fixture.coordinator.link.block, "block:nvim1", "nvim2 has not adopted the token yet")
    fixture.host.receiveEditor(.follow(fixture.envelope(second, 1, file: other)))
    XCTAssertEqual(fixture.coordinator.link.token, second)
    XCTAssertEqual(fixture.coordinator.link.block, "block:nvim2")

    fixture.host.receiveEditor(.cursor(fixture.envelope(first, 3, file: other), line: 1, top: 1, height: 20))
    XCTAssertNil(fixture.host.interaction.editorCursor, "nvim1 is no longer linked")
    fixture.host.receiveEditor(.cursor(fixture.envelope(second, 2, file: other), line: 1, top: 1, height: 20))
    XCTAssertEqual(fixture.host.interaction.editorCursor?.line, 1)

    try XCTUnwrap(fixture.waits.running("block:nvim1")).finished(try rexFixture("rex-wait-exited.json"))
    spin(until: { fixture.registry.entry(block: "block:nvim1") == nil })
    XCTAssertNil(fixture.registry.entry(block: "block:nvim1"))
    XCTAssertNotNil(fixture.registry.entry(block: "block:nvim2"))
    XCTAssertEqual(fixture.coordinator.link.block, "block:nvim2")
    XCTAssertNotEqual(fixture.status, "Editor closed")
  }

  func testARelinkKeepsTheCurrentTokenUntilThePluginAdoptsTheNewOne() throws {
    let fixture = try EditorFixture()
    let first = fixture.launchNeovim()
    let control = try XCTUnwrap(fixture.coordinator.link.controlSocket)
    fixture.press(line: 7)
    fixture.waitIdle()
    let second = try XCTUnwrap(fixture.coordinator.link.pending?.token)
    XCTAssertEqual(fixture.coordinator.link.token, first)
    XCTAssertEqual(fixture.status, "Focused the editor")

    fixture.host.receiveEditor(.follow(fixture.envelope(first, 1)))
    fixture.host.receiveEditor(.cursor(fixture.envelope(first, 2), line: 3, top: 1, height: 20))
    XCTAssertEqual(fixture.host.interaction.editorCursor?.line, 3, "the old token is heard while Neovim waits")

    var sent = fixture.control.commands.count
    fixture.host.perform(.jumpEditor(line: 12))
    spin(until: { fixture.control.commands.count == sent + 2 })
    XCTAssertEqual(
      fixture.control.commands.dropFirst(sent), [.jump(token: first, line: 12), .jump(token: second, line: 12)])
    XCTAssertEqual(
      fixture.control.sockets.dropFirst(sent), [URL(fileURLWithPath: control), URL(fileURLWithPath: control)])

    fixture.host.receiveEditor(.follow(fixture.envelope(second, 1)))
    XCTAssertEqual(fixture.coordinator.link.token, second)
    XCTAssertNil(fixture.coordinator.link.pending)
    fixture.host.receiveEditor(.cursor(fixture.envelope(first, 3), line: 5, top: 1, height: 20))
    XCTAssertNil(fixture.host.interaction.editorCursor, "the old token is dropped once adopted")

    sent = fixture.control.commands.count
    fixture.host.perform(.jumpEditor(line: 14))
    spin(until: { fixture.control.commands.count > sent })
    spin(0.05)
    XCTAssertEqual(fixture.control.commands.dropFirst(sent), [.jump(token: second, line: 14)])
  }

  func testARelinkThePluginNeverAdoptsLeavesBothSidesOnTheOldToken() throws {
    let fixture = try EditorFixture()
    let first = fixture.launchNeovim()
    fixture.host.receiveEditor(.follow(fixture.envelope(first, 1)))
    fixture.press()
    fixture.waitIdle()
    let second = try XCTUnwrap(fixture.coordinator.link.pending?.token)

    fixture.host.receiveEditor(.clean(fixture.envelope(first, 2)))
    fixture.host.receiveEditor(.cursor(fixture.envelope(first, 3), line: 4, top: 1, height: 20))
    XCTAssertEqual(fixture.coordinator.link.token, first)
    XCTAssertEqual(fixture.coordinator.link.pending?.token, second)
    XCTAssertEqual(fixture.host.interaction.editorCursor?.line, 4)
    XCTAssertEqual(fixture.host.interaction.editorLink?.followsShownFile, true)

    fixture.press()
    fixture.waitIdle()
    let third = try XCTUnwrap(fixture.coordinator.link.pending?.token)
    XCTAssertNotEqual(third, second)
    XCTAssertEqual(fixture.coordinator.link.token, first)
    let sent = fixture.control.commands.count
    fixture.host.perform(.jumpEditor(line: 9))
    spin(until: { fixture.control.commands.count == sent + 3 })
    XCTAssertEqual(
      fixture.control.commands.dropFirst(sent),
      [.jump(token: first, line: 9), .jump(token: second, line: 9), .jump(token: third, line: 9)])
  }

  func testTheEndOfANeovimThatNeverAdoptedTheRelinkKeepsTheCurrentLink() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other\n"])
    let other = fixture.hostFixture.directory.url.appendingPathComponent("other.md")
    let first = fixture.launchNeovim()
    try fixture.write(fixture.neovimEntry(block: "block:nvim2", files: [other]))
    fixture.host.open(other)
    fixture.press()
    fixture.waitIdle()
    XCTAssertEqual(fixture.coordinator.link.pending?.block, "block:nvim2")

    try XCTUnwrap(fixture.waits.running("block:nvim2")).finished(try rexFixture("rex-wait-exited.json"))
    spin(until: { fixture.registry.entry(block: "block:nvim2") == nil })
    XCTAssertNil(fixture.coordinator.link.pending)
    XCTAssertEqual(fixture.coordinator.link.token, first)
    XCTAssertEqual(fixture.coordinator.link.block, EditorFixture.launchedBlock)
    XCTAssertNotEqual(fixture.status, "Editor closed")
  }

  func testTheEndOfTheCurrentNeovimKeepsARelinkToAnotherInFlight() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other\n"])
    let other = fixture.hostFixture.directory.url.appendingPathComponent("other.md")
    fixture.launchNeovim()
    try fixture.write(fixture.neovimEntry(block: "block:nvim2", files: [other]))
    fixture.host.open(other)
    fixture.press()
    fixture.waitIdle()
    let second = try XCTUnwrap(fixture.coordinator.link.pending?.token)

    try XCTUnwrap(fixture.waits.running(EditorFixture.launchedBlock)).finished(try rexFixture("rex-wait-exited.json"))
    spin(until: { fixture.coordinator.link.block == nil })
    XCTAssertEqual(fixture.status, "Editor closed")
    XCTAssertEqual(fixture.coordinator.link.pending?.token, second)

    fixture.host.receiveEditor(.follow(fixture.envelope(second, 1, file: other)))
    XCTAssertEqual(fixture.coordinator.link.block, "block:nvim2")
    XCTAssertEqual(fixture.coordinator.link.token, second)
  }

  private func relinkToSecondNeovim(_ fixture: EditorFixture) throws -> (other: URL, token: String) {
    let other = fixture.hostFixture.directory.url.appendingPathComponent("other.md")
    try fixture.write(fixture.neovimEntry(block: "block:nvim2", files: [other]))
    fixture.host.open(other)
    fixture.press()
    fixture.waitIdle()
    let token = try XCTUnwrap(fixture.coordinator.link.pending?.token)
    XCTAssertEqual(fixture.coordinator.link.pending?.block, "block:nvim2")
    return (other, token)
  }

  func testUnlinkedOldTokenWhileARelinkOnTheSameBlockIsPendingKeepsTheWatchForTheAdoption() throws {
    let fixture = try EditorFixture()
    let first = fixture.launchNeovim()
    fixture.press()
    fixture.waitIdle()
    let second = try XCTUnwrap(fixture.coordinator.link.pending?.token)

    fixture.host.receiveEditor(.unlinked(fixture.envelope(first, 1)))
    XCTAssertNil(fixture.coordinator.link.block)
    XCTAssertEqual(fixture.status, "Editor linked to another preview")
    XCTAssertEqual(fixture.coordinator.link.pending?.token, second)
    XCTAssertNotNil(fixture.waits.running(EditorFixture.launchedBlock))

    fixture.host.receiveEditor(.follow(fixture.envelope(second, 1)))
    XCTAssertEqual(fixture.coordinator.link.token, second)
    XCTAssertEqual(fixture.coordinator.link.block, EditorFixture.launchedBlock)
    XCTAssertEqual(fixture.coordinator.watchedBlocks, [EditorFixture.launchedBlock])
    XCTAssertNotNil(fixture.waits.running(EditorFixture.launchedBlock))
  }

  func testAnAdoptionRestartsAWatchThatWasStopped() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other\n"])
    let first = fixture.launchNeovim()
    let (_, second) = try relinkToSecondNeovim(fixture)
    fixture.coordinator.watches?.stop("block:nvim2")
    XCTAssertNil(fixture.waits.running("block:nvim2"))
    XCTAssertEqual(fixture.coordinator.link.token, first)

    fixture.host.receiveEditor(.follow(fixture.envelope(second, 1)))
    XCTAssertEqual(fixture.coordinator.link.block, "block:nvim2")
    XCTAssertNotNil(fixture.waits.running("block:nvim2"))
  }

  func testUnlinkedOldTokenWhileARelinkToAnotherBlockIsPendingKeepsThePendingLink() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other\n"])
    let first = fixture.launchNeovim()
    let (other, second) = try relinkToSecondNeovim(fixture)

    fixture.host.receiveEditor(.unlinked(fixture.envelope(first, 1, file: other)))
    XCTAssertNil(fixture.coordinator.link.block)
    XCTAssertNil(fixture.waits.running(EditorFixture.launchedBlock))
    XCTAssertEqual(fixture.coordinator.link.pending?.token, second)
    XCTAssertNotNil(fixture.waits.running("block:nvim2"))

    fixture.host.receiveEditor(.follow(fixture.envelope(second, 1, file: other)))
    XCTAssertEqual(fixture.coordinator.link.block, "block:nvim2")
  }

  func testUnlinkedUnderAPendingTokenDiscardsOnlyThatToken() throws {
    let fixture = try EditorFixture()
    let first = fixture.launchNeovim()
    fixture.press()
    fixture.waitIdle()
    let second = try XCTUnwrap(fixture.coordinator.link.pending?.token)

    fixture.host.receiveEditor(.unlinked(fixture.envelope(second, 1)))
    XCTAssertNil(fixture.coordinator.link.pending)
    XCTAssertEqual(fixture.coordinator.link.token, first)
    XCTAssertEqual(fixture.coordinator.link.block, EditorFixture.launchedBlock)
    XCTAssertEqual(fixture.status, "Focused the editor")
    XCTAssertNotNil(fixture.waits.running(EditorFixture.launchedBlock))
  }

  func testExitUnderTheCurrentTokenKeepsARelinkToAnotherBlockPending() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other\n"])
    let first = fixture.launchNeovim()
    let (other, second) = try relinkToSecondNeovim(fixture)

    fixture.host.receiveEditor(.exit(fixture.envelope(first, 1, file: other)))
    XCTAssertNil(fixture.coordinator.link.block)
    XCTAssertEqual(fixture.status, "Editor closed")
    XCTAssertEqual(fixture.coordinator.link.pending?.token, second)
    XCTAssertNotNil(fixture.waits.running("block:nvim2"))
  }

  func testExitUnderAPendingTokenKeepsTheCurrentLink() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other\n"])
    let first = fixture.launchNeovim()
    let (other, second) = try relinkToSecondNeovim(fixture)

    fixture.host.receiveEditor(.exit(fixture.envelope(second, 1, file: other)))
    XCTAssertNil(fixture.coordinator.link.pending)
    XCTAssertEqual(fixture.coordinator.link.token, first)
    XCTAssertEqual(fixture.coordinator.link.block, EditorFixture.launchedBlock)
    XCTAssertNotEqual(fixture.status, "Editor closed")
    spin(until: { fixture.registry.entry(block: "block:nvim2") == nil })
    XCTAssertNil(fixture.registry.entry(block: "block:nvim2"))
  }

  func testExitUnderAPendingTokenOnTheSameBlockEndsTheLink() throws {
    let fixture = try EditorFixture()
    fixture.launchNeovim()
    fixture.press()
    fixture.waitIdle()
    let second = try XCTUnwrap(fixture.coordinator.link.pending?.token)
    XCTAssertEqual(fixture.coordinator.link.pending?.block, EditorFixture.launchedBlock)

    fixture.host.receiveEditor(.exit(fixture.envelope(second, 1)))
    XCTAssertNil(fixture.coordinator.link.block)
    XCTAssertNil(fixture.coordinator.link.token)
    XCTAssertNil(fixture.coordinator.link.pending)
    XCTAssertEqual(fixture.status, "Editor closed")
    XCTAssertNil(fixture.waits.running(EditorFixture.launchedBlock))
    spin(until: { fixture.registry.entry(block: EditorFixture.launchedBlock) == nil })
    XCTAssertNil(fixture.registry.entry(block: EditorFixture.launchedBlock))
  }

  func testAnEarlierRelinkThatSucceedsIsAdoptedWhenALaterOneFails() throws {
    let fixture = try EditorFixture()
    let first = fixture.launchNeovim()
    fixture.press()
    fixture.waitIdle()
    let second = try XCTUnwrap(fixture.coordinator.link.pending?.token)
    fixture.press()
    fixture.waitIdle()
    let third = try XCTUnwrap(fixture.coordinator.link.pending?.token)
    XCTAssertEqual(fixture.coordinator.link.pendings.map(\.token), [second, third])

    var sent = fixture.control.commands.count
    fixture.host.receiveEditor(.follow(fixture.envelope(first, 1)))
    fixture.host.perform(.jumpEditor(line: 6))
    spin(until: { fixture.control.commands.count == sent + 3 })
    XCTAssertEqual(
      fixture.control.commands.dropFirst(sent),
      [.jump(token: first, line: 6), .jump(token: second, line: 6), .jump(token: third, line: 6)])

    fixture.host.receiveEditor(.follow(fixture.envelope(second, 1)))
    fixture.host.receiveEditor(.cursor(fixture.envelope(second, 2), line: 8, top: 1, height: 20))
    XCTAssertEqual(fixture.coordinator.link.token, second)
    XCTAssertEqual(fixture.coordinator.link.pendings.map(\.token), [third])
    XCTAssertEqual(fixture.host.interaction.editorCursor?.line, 8)
    fixture.host.receiveEditor(.cursor(fixture.envelope(first, 2), line: 2, top: 1, height: 20))
    XCTAssertEqual(fixture.host.interaction.editorCursor?.line, 8, "the first token is no longer heard")

    sent = fixture.control.commands.count
    fixture.host.perform(.jumpEditor(line: 9))
    spin(until: { fixture.control.commands.count == sent + 2 })
    XCTAssertEqual(
      fixture.control.commands.dropFirst(sent), [.jump(token: second, line: 9), .jump(token: third, line: 9)])
  }

  func testARelinkToAnotherNeovimReplacesEarlierPendingRelinks() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other\n"])
    fixture.launchNeovim()
    fixture.press()
    fixture.waitIdle()
    let (_, second) = try relinkToSecondNeovim(fixture)
    XCTAssertEqual(fixture.coordinator.link.pendings.map(\.token), [second])
  }

  func testTheEndOfTheLinkedBlockClearsTheLinkAndThePreviewStaysOpen() throws {
    let fixture = try EditorFixture()
    var quit = false
    fixture.host.onQuit = { quit = true }
    let token = fixture.launchNeovim()
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 1), text: try fixture.writeBuffer("# Unsaved\n")))
    fixture.host.receiveEditor(.cursor(fixture.envelope(token, 2), line: 1, top: 1, height: 20))
    try XCTUnwrap(fixture.waits.running(EditorFixture.launchedBlock))
      .finished(try rexFixture("rex-wait-closed.json"))
    spin(until: { fixture.coordinator.link.block == nil })
    XCTAssertNil(fixture.coordinator.link.token)
    XCTAssertNil(fixture.host.interaction.editorLink)
    XCTAssertNil(fixture.host.interaction.editorCursor)
    XCTAssertFalse(fixture.host.interaction.liveBuffer)
    XCTAssertEqual(fixture.status, "Editor closed")
    XCTAssertFalse(quit)
    spin(until: { fixture.registry.entry(block: EditorFixture.launchedBlock) == nil })
    XCTAssertNil(fixture.registry.entry(block: EditorFixture.launchedBlock))
  }

  func testAFailedControlConnectDiscardsThePendingTokenAndKeepsThePreviousLink() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other\n"])
    let other = fixture.hostFixture.directory.url.appendingPathComponent("other.md")
    let token = fixture.launchNeovim()
    fixture.host.receiveEditor(.follow(fixture.envelope(token, 1, file: other)))
    fixture.host.open(fixture.file)
    fixture.control.succeeds = false
    fixture.press()
    fixture.waitIdle()
    XCTAssertEqual(fixture.control.commands.count, 1)
    XCTAssertNil(fixture.coordinator.link.pending)
    XCTAssertEqual(fixture.coordinator.link.token, token)
    XCTAssertEqual(fixture.coordinator.link.block, EditorFixture.launchedBlock)
    XCTAssertEqual(
      fixture.runner.rexCalls.last, ["block", "inspect", "-s", EditorFixture.session, EditorFixture.launchedBlock])
    XCTAssertEqual(fixture.status, "Could not reach Neovim")
    fixture.host.receiveEditor(.cursor(fixture.envelope(token, 2), line: 1, top: 1, height: 20))
    XCTAssertNotNil(fixture.host.interaction.editorCursor)
  }

  func testAnEditAppliesAfterPluginMessages() throws {
    let fixture = try EditorFixture(files: ["other.md": "# Other\n"])
    let other = fixture.hostFixture.directory.url.appendingPathComponent("other.md")
    let token = fixture.launchNeovim()
    let control = ViewerControl()
    control.onEditorMessage = { fixture.host.receiveEditor($0) }
    control.receive(editor: .follow(fixture.envelope(token, 1, file: other)))
    control.receive(editor: .edit(mode: .alternate, line: 4))
    control.attach(fixture.host)
    fixture.waitIdle()
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "other.md")
    XCTAssertEqual(fixture.handoffs.last?.command.suffix(2), ["+4", other.path])
  }

  func testAVimEnterSnapshotUnderThePendingTokenIsKeptAndAttachesWhenTheBlockArrives() throws {
    let fixture = try EditorFixture()
    let gate = DispatchSemaphore(value: 0)
    fixture.runner.runGate = gate
    fixture.press()
    spin(until: { fixture.coordinator.link.pending != nil })
    let token = try XCTUnwrap(fixture.coordinator.link.pending?.token)
    fixture.host.receiveEditor(.follow(fixture.envelope(token, 1)))
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 2), text: try fixture.writeBuffer("# Early\n")))
    fixture.host.receiveEditor(.cursor(fixture.envelope(token, 3), line: 1, top: 1, height: 20))
    XCTAssertEqual(fixture.host.interaction.source, "# Early\n")
    XCTAssertTrue(fixture.host.interaction.liveBuffer)
    XCTAssertNotNil(fixture.host.interaction.editorCursor)
    XCTAssertNil(fixture.coordinator.link.block)
    gate.signal()
    fixture.waitIdle()
    XCTAssertEqual(fixture.coordinator.link.block, EditorFixture.launchedBlock)
    XCTAssertEqual(fixture.coordinator.link.token, token)
    XCTAssertTrue(fixture.host.interaction.liveBuffer)
    XCTAssertEqual(fixture.host.interaction.status.editor, "Neovim: unsaved")
  }

  func testALaunchFailureAfterAnEarlySnapshotDiscardsTheTokenAndReloads() throws {
    let fixture = try EditorFixture()
    let gate = DispatchSemaphore(value: 0)
    fixture.runner.runGate = gate
    fixture.runner.queueRun((1, Data(), Data("boom".utf8)))
    fixture.press()
    spin(until: { fixture.coordinator.link.pending != nil })
    let token = try XCTUnwrap(fixture.coordinator.link.pending?.token)
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 1), text: try fixture.writeBuffer("# Early\n")))
    XCTAssertTrue(fixture.host.interaction.liveBuffer)
    gate.signal()
    fixture.waitIdle()
    settled(fixture)
    XCTAssertNil(fixture.coordinator.link.pending)
    XCTAssertNil(fixture.coordinator.link.block)
    XCTAssertFalse(fixture.host.interaction.liveBuffer)
    XCTAssertEqual(fixture.host.interaction.source, try String(contentsOf: fixture.file, encoding: .utf8))
    XCTAssertEqual(fixture.status, "Could not open Neovim")
    fixture.host.receiveEditor(.buffer(fixture.envelope(token, 2), text: try fixture.writeBuffer("# Late\n")))
    XCTAssertFalse(fixture.host.interaction.liveBuffer)
  }
}
