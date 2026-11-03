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

  func testPreviewModeDefaultsToPerFile() throws {
    let base = Config(rexPath: "/r", mdViewerPath: "/m", previousHandlers: [:])
    XCTAssertEqual(base.previewMode, .perFile)
    for (value, mode) in [("perFile", PreviewMode.perFile), ("single", .single), ("bogus", .perFile), ("", .perFile)] {
      var config = base
      config.previews = value
      XCTAssertEqual(config.previewMode, mode, value)
    }
  }

  func testUnknownPreviewsValueStillLoads() throws {
    let paths = SupportPaths(home: temporaryHome())
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    let json = #"{"rexPath":"/r","mdViewerPath":"/m","previousHandlers":{},"previews":"tabs"}"#
    try Data(json.utf8).write(to: paths.configFile)
    let config = try XCTUnwrap(try ConfigStore.load(paths))
    XCTAssertEqual(config.previews, "tabs")
    XCTAssertEqual(config.previewMode, .perFile)
  }

  func testANonStringPreviewsValueLoadsTheRestAsPerFile() throws {
    let paths = SupportPaths(home: temporaryHome())
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    for value in ["true", "3", "[\"single\"]", "{}", "null"] {
      let json = #"{"rexPath":"/r","mdViewerPath":"/m","previousHandlers":{"t":"com.x"},"previews":"# + value + "}"
      try Data(json.utf8).write(to: paths.configFile)
      let config = try XCTUnwrap(try ConfigStore.load(paths), value)
      XCTAssertEqual(config.previousHandlers, ["t": "com.x"], value)
      XCTAssertNil(config.previews, value)
      XCTAssertEqual(config.previewMode, .perFile, value)
    }
  }

  func testSavingKeepsExistingKeysTheConfigDoesNotSet() throws {
    let paths = SupportPaths(home: temporaryHome())
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    let json = #"{"rexPath":"/old","mdViewerPath":"/m","previousHandlers":{},"previews":"single","future":[1,2]}"#
    try Data(json.utf8).write(to: paths.configFile)
    try ConfigStore.save(Config(rexPath: "/new", mdViewerPath: "/m", previousHandlers: ["t": "com.x"]), paths)
    let loaded = try XCTUnwrap(try ConfigStore.load(paths))
    XCTAssertEqual(loaded.rexPath, "/new")
    XCTAssertEqual(loaded.previousHandlers, ["t": "com.x"])
    XCTAssertEqual(loaded.previewMode, .single)
    let raw = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(contentsOf: paths.configFile)) as? [String: Any])
    XCTAssertEqual(raw["future"] as? [Int], [1, 2])
    var perFile = loaded
    perFile.previews = "perFile"
    try ConfigStore.save(perFile, paths)
    XCTAssertEqual(try ConfigStore.load(paths)?.previewMode, .perFile)
  }

  func testSavingOverACorruptFileStartsFresh() throws {
    let paths = SupportPaths(home: temporaryHome())
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: paths.configFile)
    let config = Config(rexPath: "/r", mdViewerPath: "/m", previousHandlers: [:])
    try ConfigStore.save(config, paths)
    XCTAssertEqual(try ConfigStore.load(paths), config)
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
