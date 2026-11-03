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
    XCTAssertEqual(parseViewerMessage("state", fileExists: ok), .state)
    XCTAssertNil(parseViewerMessage("state ", fileExists: ok))
  }

  private func socketDirectory() throws -> URL {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent(String(UUID().uuidString.prefix(8)))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  func testStateQueryReportsTheShownFileOpenerAndOpenTime() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sock = dir.appendingPathComponent("s.sock")
    let status = ViewerStatus(opener: "block:caller", openedAt: 42)
    let server = try ViewerSocketServer(socket: sock, status: status) { _ in XCTFail("not an open message") }
    defer { server.close() }
    XCTAssertEqual(
      ViewerSocketClient.query(sock), .answered(ViewerState(file: nil, openedAt: 42, opener: "block:caller")))
    status.show(URL(fileURLWithPath: "/tmp/a \"b\"\nc.md"))
    XCTAssertEqual(
      ViewerSocketClient.query(sock),
      .answered(ViewerState(file: "/tmp/a \"b\"\nc.md", openedAt: 42, opener: "block:caller")))
    status.show(URL(fileURLWithPath: "/tmp/linked.md"))
    if case .answered(let state) = ViewerSocketClient.query(sock) {
      XCTAssertEqual(state.file, "/tmp/linked.md")
    } else {
      XCTFail("expected an answer")
    }
  }

  func testAStartingViewerReportsTheRequestedFileBeforeItIsShown() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sock = dir.appendingPathComponent("r.sock")
    let status = ViewerStatus(file: URL(fileURLWithPath: "/tmp/requested.md"), opener: "block:caller", openedAt: 7)
    let server = try ViewerSocketServer(socket: sock, status: status) { _ in }
    defer { server.close() }
    XCTAssertEqual(
      ViewerSocketClient.query(sock),
      .answered(ViewerState(file: "/tmp/requested.md", openedAt: 7, opener: "block:caller")))
  }

  func testTheSocketAppearsOnlyOnceListeningAndReplacesAStaleFile() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sock = dir.appendingPathComponent("n.sock")
    FileManager.default.createFile(atPath: sock.path, contents: Data("stale".utf8))
    let server = try ViewerSocketServer(socket: sock, status: ViewerStatus(opener: nil)) { _ in }
    defer { server.close() }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["n.sock"])
    let attributes = try FileManager.default.attributesOfItem(atPath: sock.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    guard case .answered = ViewerSocketClient.query(sock) else { return XCTFail("expected an answer") }
  }

  func testProbingAStartingViewerNeverRemovesItsSocket() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = (0..<100).map { dir.appendingPathComponent("\($0).sock") }
    let current = NSLock()
    nonisolated(unsafe) var index = 0
    nonisolated(unsafe) var done = false
    let stopped = DispatchSemaphore(value: 0)
    let prober = Thread {
      while !current.withLock({ done }) {
        _ = ViewerSocketClient.query(paths[current.withLock { index }])
      }
      stopped.signal()
    }
    prober.start()
    var servers: [ViewerSocketServer] = []
    defer { for server in servers { server.close() } }
    defer {
      current.withLock { done = true }
      stopped.wait()
    }
    for (position, path) in paths.enumerated() {
      current.withLock { index = position }
      Thread.sleep(forTimeInterval: 0.001)
      servers.append(try ViewerSocketServer(socket: path, status: ViewerStatus(opener: nil)) { _ in })
      XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), path.lastPathComponent)
    }
    for path in paths {
      guard case .answered = ViewerSocketClient.query(path) else { return XCTFail("\(path.lastPathComponent) lost") }
    }
  }

  func testAViewerWithoutStatusIsSilentAndAMissingOneUnreachable() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sock = dir.appendingPathComponent("o.sock")
    let server = try ViewerSocketServer(socket: sock) { _ in }
    XCTAssertEqual(ViewerSocketClient.query(sock), .silent)
    server.close()
    XCTAssertEqual(ViewerSocketClient.query(sock), .unreachable)
    FileManager.default.createFile(atPath: sock.path, contents: nil)
    XCTAssertEqual(ViewerSocketClient.query(sock), .unreachable)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sock.path))
  }

  func testAStaleSocketFromACrashedViewerIsUnreachableAndRemoved() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sock = dir.appendingPathComponent("c.sock")
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = try XCTUnwrap(socketAddress(path: sock.path))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    close(fd)
    XCTAssertTrue(FileManager.default.fileExists(atPath: sock.path))
    XCTAssertEqual(ViewerSocketClient.query(sock), .unreachable)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sock.path))
  }

  func testAViewerThatNeverAnswersIsSilentWithinTheTimeout() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sock = dir.appendingPathComponent("h.sock")
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = try XCTUnwrap(socketAddress(path: sock.path))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    XCTAssertEqual(listen(fd, 8), 0)
    let started = Date()
    XCTAssertEqual(ViewerSocketClient.query(sock), .silent)
    XCTAssertLessThan(Date().timeIntervalSince(started), 3)
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
