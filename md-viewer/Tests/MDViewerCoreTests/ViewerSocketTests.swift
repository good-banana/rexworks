import XCTest

@testable import MDViewerCore

final class ViewerSocketTests: XCTestCase {
  func testValidation() {
    let ok: (String) -> Bool = { _ in true }
    XCTAssertEqual(validateOpenMessage("/tmp/a b.md\n", fileExists: ok)?.path, "/tmp/a b.md")
    XCTAssertNil(validateOpenMessage("relative.md", fileExists: ok))
    XCTAssertNil(validateOpenMessage("/tmp/a.txt", fileExists: ok))
    XCTAssertNil(validateOpenMessage("/tmp/a\u{0}.md", fileExists: ok))
    XCTAssertNil(validateOpenMessage("/tmp/a.md\u{0}", fileExists: ok))
    XCTAssertNil(validateOpenMessage("/tmp/missing.md", fileExists: { _ in false }))
    XCTAssertNil(validateOpenMessage("/" + String(repeating: "a", count: 4096) + ".md", fileExists: ok))
  }

  func testThemeCommandIsStrictAndPathsStillWork() {
    let ok: (String) -> Bool = { _ in true }
    XCTAssertEqual(parseViewerMessage("theme", fileExists: ok), .theme)
    for line in ["theme ", " theme", "THEME", "theme\u{0}", "themes", "theme;rm"] {
      XCTAssertNil(parseViewerMessage(line, fileExists: ok), line.debugDescription)
    }
    XCTAssertEqual(parseViewerMessage("/tmp/a.md", fileExists: ok), .open(URL(fileURLWithPath: "/tmp/a.md")))
    XCTAssertNil(parseViewerMessage("/tmp/theme", fileExists: ok))
  }

  func testThemeMessagesReachTheServer() throws {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent(String(UUID().uuidString.prefix(8)))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sock = dir.appendingPathComponent("t.sock")
    let got = expectation(description: "theme")
    let server = try ViewerSocketServer(
      socket: sock, onOpen: { _ in XCTFail("not an open message") }, onTheme: { got.fulfill() })
    defer { server.close() }
    XCTAssertEqual(server.path, sock)
    XCTAssertTrue(ViewerSocketClient.sendTheme(to: sock))
    wait(for: [got], timeout: 2)
  }

  func testSendWithoutServerFails() {
    let missing = URL(fileURLWithPath: "/tmp/\(UUID().uuidString.prefix(8)).sock")
    XCTAssertFalse(ViewerSocketClient.send(path: "/tmp/x.md", to: missing))
  }

  func testRoundTripAndStaleCleanup() throws {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent(String(UUID().uuidString.prefix(8)))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sock = dir.appendingPathComponent("b.sock")
    let file = dir.appendingPathComponent("x.md")
    try "# x".write(to: file, atomically: true, encoding: .utf8)
    let got = expectation(description: "open")
    let server = try ViewerSocketServer(socket: sock) { url in
      XCTAssertEqual(url.path, file.path)
      got.fulfill()
    }
    let mode = try FileManager.default.attributesOfItem(atPath: sock.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)
    XCTAssertTrue(ViewerSocketClient.send(path: file.path, to: sock))
    wait(for: [got], timeout: 2)
    server.close()
    XCTAssertFalse(FileManager.default.fileExists(atPath: sock.path))
    FileManager.default.createFile(atPath: sock.path, contents: nil)
    XCTAssertFalse(ViewerSocketClient.send(path: file.path, to: sock))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sock.path))
  }

  func testExitHookRemovesOpenSocketFile() throws {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent(String(UUID().uuidString.prefix(8)))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sock = dir.appendingPathComponent("b.sock")
    let server = try ViewerSocketServer(socket: sock) { _ in }
    XCTAssertTrue(FileManager.default.fileExists(atPath: sock.path))
    removeViewerSocketFiles()
    XCTAssertFalse(FileManager.default.fileExists(atPath: sock.path))
    server.close()
  }

  func testRejectsInvalidMessages() throws {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent(String(UUID().uuidString.prefix(8)))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sock = dir.appendingPathComponent("b.sock")
    let bad = dir.appendingPathComponent("x.txt")
    try "x".write(to: bad, atomically: true, encoding: .utf8)
    let rejected = expectation(description: "none")
    rejected.isInverted = true
    let server = try ViewerSocketServer(socket: sock) { _ in rejected.fulfill() }
    XCTAssertTrue(ViewerSocketClient.send(path: bad.path, to: sock))
    XCTAssertTrue(ViewerSocketClient.send(path: dir.path + "/x.md", to: sock))
    wait(for: [rejected], timeout: 0.5)
    server.close()
  }
}
