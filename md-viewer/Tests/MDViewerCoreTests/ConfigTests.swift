import XCTest

@testable import MDViewerCore

final class ConfigTests: XCTestCase {
  private func temporaryHome() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  func testRoundTripWithPrivatePermissions() throws {
    let paths = SupportPaths(home: temporaryHome())
    let config = Config(
      rexPath: "/opt/homebrew/bin/rex",
      mdViewerPath: "/opt/homebrew/bin/md-viewer",
      previousHandlers: ["net.daringfireball.markdown": "com.apple.TextEdit"])
    try ConfigStore.save(config, paths)
    XCTAssertEqual(try ConfigStore.load(paths), config)
    let fileMode = try FileManager.default.attributesOfItem(atPath: paths.configFile.path)[.posixPermissions] as? Int
    let dirMode = try FileManager.default.attributesOfItem(atPath: paths.root.path)[.posixPermissions] as? Int
    XCTAssertEqual(fileMode, 0o600)
    XCTAssertEqual(dirMode, 0o700)
  }

  func testLoadMissingReturnsNil() throws {
    XCTAssertNil(try ConfigStore.load(SupportPaths(home: temporaryHome())))
  }

  func testViewerSocketPath() {
    let paths = SupportPaths(home: URL(fileURLWithPath: "/Users/x"))
    let socket = paths.viewerSocket(block: "block:01ab")
    XCTAssertEqual(socket.deletingLastPathComponent().path, paths.viewersDirectory.path)
    XCTAssertEqual(socket.lastPathComponent.count, 21)
    XCTAssertTrue(socket.lastPathComponent.hasSuffix(".sock"))
    XCTAssertEqual(socket, paths.viewerSocket(block: "block:01ab"))
    XCTAssertNotEqual(socket, paths.viewerSocket(block: "block:01ac"))
  }

  func testViewerSocketFitsSunPathForLongHome() {
    let home = URL(fileURLWithPath: "/Users/" + String(repeating: "a", count: 20))
    let socket = SupportPaths(home: home).viewerSocket(
      block: "block:01a193b6-fe81-72ee-bab7-569aa3a4f5ca")
    XCTAssertLessThan(socket.path.utf8.count, 104)
  }

  func testDerivedPaths() {
    let paths = SupportPaths(home: URL(fileURLWithPath: "/Users/x"))
    let root = "/Users/x/Library/Application Support/md-viewer"
    XCTAssertEqual(paths.configFile.path, "\(root)/config.json")
    XCTAssertEqual(paths.handlerLog.path, "\(root)/handler.log")
    XCTAssertEqual(paths.viewersDirectory.path, "\(root)/viewers")
    XCTAssertEqual(paths.viewerLog.path, "\(root)/viewer.log")
    XCTAssertEqual(paths.installedApp.path, "/Users/x/Applications/MD Viewer.app")
  }
}
