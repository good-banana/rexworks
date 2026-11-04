import Darwin
import XCTest

@testable import MDViewerCore

final class PrivateFileTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func mode(_ url: URL) throws -> Int {
    try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
  }

  func testWriteIsPrivateBeforeItIsRenamedIntoPlace() throws {
    let url = directory.appendingPathComponent("config.json")
    try Data("old".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    let previous = umask(0o022)
    defer { umask(previous) }
    var stagedMode: Int?
    var stagedDirectory: URL?
    try PrivateFile.write(Data("new".utf8), to: url) { temp in
      stagedMode = try self.mode(temp)
      stagedDirectory = temp.deletingLastPathComponent()
    }
    XCTAssertEqual(stagedMode, 0o600)
    XCTAssertEqual(stagedDirectory?.standardizedFileURL, directory.standardizedFileURL)
    XCTAssertEqual(try mode(url), 0o600)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["config.json"])
  }

  func testFailedWriteLeavesTheOldFileAndNoTemp() throws {
    let url = directory.appendingPathComponent("config.json")
    try Data("old".utf8).write(to: url)
    struct Stop: Error {}
    XCTAssertThrowsError(try PrivateFile.write(Data("new".utf8), to: url) { _ in throw Stop() })
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["config.json"])
  }

  func testRestrictTightensALooseMode() throws {
    let url = directory.appendingPathComponent("plugin.lua")
    try Data("x".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    try PrivateFile.restrict(url)
    XCTAssertEqual(try mode(url), 0o600)
  }
}
