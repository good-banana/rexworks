import Foundation
import XCTest

@testable import MDViewerCore

final class RexFindBindingTests: XCTestCase {
  private var directory: URL!
  private let editor = RexFindBinding.Editor(runner: nil, rexPath: nil)

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testConfigFileFollowsRexRules() {
    let home = URL(fileURLWithPath: "/Users/me")
    XCTAssertEqual(
      RexFindBinding.configFile(environment: ["REX_CONFIG": "/tmp/rex.lua"], home: home).path, "/tmp/rex.lua")
    XCTAssertEqual(
      RexFindBinding.configFile(environment: ["XDG_CONFIG_HOME": "/cfg"], home: home).path, "/cfg/rex/init.lua")
    XCTAssertEqual(RexFindBinding.configFile(environment: [:], home: home).path, "/Users/me/.config/rex/init.lua")
    XCTAssertEqual(
      RexFindBinding.configFile(environment: ["REX_CONFIG": "", "XDG_CONFIG_HOME": ""], home: home).path,
      "/Users/me/.config/rex/init.lua")
  }

  func testInstallCreatesTheFileAndIsIdempotent() throws {
    let config = directory.appendingPathComponent("rex/init.lua")
    XCTAssertTrue(try editor.install(at: config))
    let first = try String(contentsOf: config, encoding: .utf8)
    XCTAssertEqual(first, RexFindBinding.lua + "\n")
    XCTAssertFalse(try editor.install(at: config), "a second install changes nothing")
    XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), first)
    XCTAssertTrue(first.contains("rex.bind(\"cmd+f\", \"md_viewer_find\")"))
    XCTAssertTrue(first.contains("client.find.open"))
    XCTAssertTrue(first.contains("\\27[102;9u"), "Cmd-F in the kitty encoding")
  }

  func testInstallKeepsTheUsersConfigAndReplacesAnOldBlock() throws {
    let config = directory.appendingPathComponent("init.lua")
    let mine = "require(\"nubs-tasks\")\nrex.bind(\"cmd+e\", \"pane.zoom\")\n"
    let stale = "\(RexFindBinding.beginMarker)\nold contents\n\(RexFindBinding.endMarker)\n"
    try (mine + "\n" + stale + "-- after\n").write(to: config, atomically: true, encoding: .utf8)
    XCTAssertTrue(try editor.install(at: config))
    let text = try String(contentsOf: config, encoding: .utf8)
    XCTAssertTrue(text.hasPrefix(mine))
    XCTAssertTrue(text.contains("-- after"))
    XCTAssertFalse(text.contains("old contents"))
    XCTAssertEqual(text.components(separatedBy: RexFindBinding.beginMarker).count, 2, "exactly one block")
    XCTAssertTrue(try editor.remove(at: config))
    XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), mine + "\n-- after\n")
    XCTAssertFalse(try editor.remove(at: config))
  }

  func testInstallAndRemoveRoundTripExactly() throws {
    let config = directory.appendingPathComponent("init.lua")
    for original in ["require(\"x\")\n", "require(\"x\")", "", "a\n\n\nb\n"] {
      try original.write(to: config, atomically: true, encoding: .utf8)
      try editor.install(at: config)
      try editor.remove(at: config)
      XCTAssertEqual(
        try String(contentsOf: config, encoding: .utf8).trimmingCharacters(in: .newlines),
        original.trimmingCharacters(in: .newlines), original.debugDescription)
    }
  }

  func testASymlinkedConfigStaysASymlink() throws {
    let target = directory.appendingPathComponent("dotfiles/init.lua")
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "require(\"x\")\n".write(to: target, atomically: true, encoding: .utf8)
    let link = directory.appendingPathComponent("init.lua")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    try editor.install(at: link)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains(RexFindBinding.beginMarker))
  }

  func testAFileThatIsNotUTF8IsLeftAlone() throws {
    let config = directory.appendingPathComponent("init.lua")
    let original = Data([0x2d, 0x2d, 0x20, 0xe9, 0x74, 0xe9, 0x0a])
    try original.write(to: config)
    XCTAssertThrowsError(try editor.install(at: config)) {
      XCTAssertEqual($0 as? RexFindBinding.EditError, .notUTF8)
    }
    XCTAssertEqual(try Data(contentsOf: config), original)
  }

  func testAnUnreadableFileIsLeftAlone() throws {
    let config = directory.appendingPathComponent("init.lua")
    try "require(\"x\")\n".write(to: config, atomically: true, encoding: .utf8)
    XCTAssertEqual(chmod(config.path, 0o200), 0)
    defer { chmod(config.path, 0o600) }
    XCTAssertThrowsError(try editor.install(at: config)) {
      guard case .unreadable = $0 as? RexFindBinding.EditError else { return XCTFail("\($0)") }
    }
    chmod(config.path, 0o600)
    XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "require(\"x\")\n")
  }

  func testAMissingEndMarkerStopsTheEdit() throws {
    let config = directory.appendingPathComponent("init.lua")
    let original = "a\n\(RexFindBinding.beginMarker)\nhalf a block\nrex.bind(\"cmd+e\", \"pane.zoom\")\n"
    try original.write(to: config, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try editor.install(at: config)) {
      XCTAssertEqual($0 as? RexFindBinding.EditError, .unterminatedBlock)
    }
    XCTAssertThrowsError(try editor.remove(at: config))
    XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
  }

  func testTheCandidateMustPassRexConfigCheck() throws {
    let config = directory.appendingPathComponent("init.lua")
    let original = "return {}\n"
    try original.write(to: config, atomically: true, encoding: .utf8)
    let failing = FakeRunner(
      status: 1, output: "error init.lua:3: syntax error near 'local'\nError: the configuration has errors")
    XCTAssertThrowsError(try RexFindBinding.Editor(runner: failing, rexPath: "/usr/bin/rex").install(at: config)) {
      XCTAssertEqual(
        $0 as? RexFindBinding.EditError,
        .checkFailed("error init.lua:3: syntax error near 'local'; Error: the configuration has errors"))
    }
    XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
    XCTAssertEqual(failing.calls.count, 1)
    XCTAssertEqual(failing.calls.first?.executable, "/usr/bin/rex")
    XCTAssertEqual(failing.calls.first?.arguments.first, "config")
    XCTAssertEqual(failing.calls.first?.arguments.last, "--autostart=false")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(leftovers, ["init.lua"], "the candidate file is cleaned up")

    let passing = FakeRunner(status: 0, output: "")
    XCTAssertTrue(try RexFindBinding.Editor(runner: passing, rexPath: "/usr/bin/rex").install(at: config))
    XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains(RexFindBinding.beginMarker))
    let checked = try XCTUnwrap(passing.calls.first?.arguments[2])
    XCTAssertNotEqual(checked, config.path, "the candidate, not the real file, is checked")
    XCTAssertEqual(URL(fileURLWithPath: checked).deletingLastPathComponent().path, directory.path)
  }

  func testTheCandidateIsSyncedBeforeItReplacesTheFile() throws {
    let config = directory.appendingPathComponent("init.lua")
    try "a\n".write(to: config, atomically: true, encoding: .utf8)
    var synced: [(URL, String)] = []
    let editor = RexFindBinding.Editor(runner: nil, rexPath: nil) { url in
      synced.append((url, try String(contentsOf: url, encoding: .utf8)))
    }
    try editor.install(at: config)
    XCTAssertEqual(synced.count, 1)
    XCTAssertNotEqual(synced.first?.0, config, "the candidate is synced, not the original")
    XCTAssertEqual(synced.first?.1, try String(contentsOf: config, encoding: .utf8), "with the final contents")
    try RexFindBinding.Editor.fsync(config)
  }

  func testABrokenConfigCanStillHaveTheBlockRemoved() throws {
    let config = directory.appendingPathComponent("init.lua")
    try "return {}\n".write(to: config, atomically: true, encoding: .utf8)
    try RexFindBinding.Editor(runner: nil, rexPath: nil).install(at: config)
    let failing = FakeRunner(status: 1, output: "error init.lua:3: syntax error")
    XCTAssertTrue(try RexFindBinding.Editor(runner: failing, rexPath: "/usr/bin/rex").remove(at: config))
    XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "return {}\n")
    XCTAssertEqual(failing.calls.count, 1, "only the original was checked; its failure skips the candidate check")
    XCTAssertEqual(failing.calls.first?.arguments[2], config.path)
  }

  func testRemovingFromAValidConfigStillChecksTheCandidate() throws {
    let config = directory.appendingPathComponent("init.lua")
    try "require(\"x\")\n".write(to: config, atomically: true, encoding: .utf8)
    try RexFindBinding.Editor(runner: nil, rexPath: nil).install(at: config)
    let passing = FakeRunner(status: 0, output: "")
    XCTAssertTrue(try RexFindBinding.Editor(runner: passing, rexPath: "/usr/bin/rex").remove(at: config))
    XCTAssertEqual(passing.calls.count, 2, "the original, then the candidate")
    XCTAssertNotEqual(passing.calls.last?.arguments[2], config.path)
  }

  func testWritesAreAtomicAndKeepPermissions() throws {
    let config = directory.appendingPathComponent("init.lua")
    try "require(\"x\")\n".write(to: config, atomically: true, encoding: .utf8)
    XCTAssertEqual(chmod(config.path, 0o600), 0)
    let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: config.path)[.systemFileNumber] as? Int)
    try editor.install(at: config)
    let attributes = try FileManager.default.attributesOfItem(atPath: config.path)
    XCTAssertNotEqual(attributes[.systemFileNumber] as? Int, before, "replaced by rename")
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
  }
}

final class UninstallOrderTests: XCTestCase {
  func testTheBindingIsRemovedOnlyAfterAFullRestore() async throws {
    var removed = 0
    let failed = await uninstallThenRemoveFindBinding(
      restore: { ["could not restore net.daringfireball.markdown"] }, removeFindBinding: { removed += 1 })
    XCTAssertEqual(failed.count, 1)
    XCTAssertEqual(removed, 0, "a failed restore keeps the binding with the app and config")
    struct Broken: Error {}
    do {
      _ = try await uninstallThenRemoveFindBinding(restore: { throw Broken() }, removeFindBinding: { removed += 1 })
      XCTFail("the error propagates")
    } catch {}
    XCTAssertEqual(removed, 0)
    let done = await uninstallThenRemoveFindBinding(restore: { [] }, removeFindBinding: { removed += 1 })
    XCTAssertTrue(done.isEmpty)
    XCTAssertEqual(removed, 1)
  }
}

final class FakeRunner: ProcessRunning, @unchecked Sendable {
  var status: Int32
  let output: String
  var calls: [(executable: String, arguments: [String])] = []

  init(status: Int32, output: String) {
    self.status = status
    self.output = output
  }

  func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> (
    status: Int32, stdout: Data, stderr: Data
  ) {
    calls.append((executable, arguments))
    return (status, Data(output.utf8), Data())
  }
}
