import Foundation
import XCTest

@testable import MDViewerCore

final class RexFindBindingTests: XCTestCase {
  private var directory: URL!

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
    XCTAssertTrue(try RexFindBinding.install(at: config))
    let first = try String(contentsOf: config, encoding: .utf8)
    XCTAssertEqual(first, RexFindBinding.lua + "\n")
    XCTAssertFalse(try RexFindBinding.install(at: config), "a second install changes nothing")
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
    XCTAssertTrue(try RexFindBinding.install(at: config))
    let text = try String(contentsOf: config, encoding: .utf8)
    XCTAssertTrue(text.hasPrefix(mine))
    XCTAssertTrue(text.contains("-- after"))
    XCTAssertFalse(text.contains("old contents"))
    XCTAssertEqual(text.components(separatedBy: RexFindBinding.beginMarker).count, 2, "exactly one block")
    XCTAssertTrue(try RexFindBinding.remove(at: config))
    XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), mine + "\n-- after\n")
    XCTAssertFalse(try RexFindBinding.remove(at: config))
  }

  func testInstallAndRemoveRoundTripExactly() throws {
    let config = directory.appendingPathComponent("init.lua")
    for original in ["require(\"x\")\n", "require(\"x\")", "", "a\n\n\nb\n"] {
      try original.write(to: config, atomically: true, encoding: .utf8)
      try RexFindBinding.install(at: config)
      try RexFindBinding.remove(at: config)
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
    try RexFindBinding.install(at: link)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains(RexFindBinding.beginMarker))
  }
}
