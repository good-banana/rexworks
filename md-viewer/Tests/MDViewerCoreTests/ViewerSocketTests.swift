import Darwin
import Foundation
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
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    var address = try XCTUnwrap(socketAddress(path: sock.path))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    Darwin.close(fd)
    XCTAssertTrue(FileManager.default.fileExists(atPath: sock.path))
    XCTAssertEqual(ViewerSocketClient.query(sock), .unreachable)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sock.path))
  }

  func testAViewerThatNeverAnswersIsSilentWithinTheTimeout() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sock = dir.appendingPathComponent("h.sock")
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
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

  private func buffersFixture() throws -> (root: URL, buffers: URL, buffer: URL) {
    let root = try socketDirectory()
    let buffers = root.appendingPathComponent("buffers", isDirectory: true)
    try FileManager.default.createDirectory(at: buffers, withIntermediateDirectories: true)
    let buffer = buffers.appendingPathComponent("1-2.md")
    try "# x".write(to: buffer, atomically: true, encoding: .utf8)
    return (root, buffers, buffer)
  }

  private func plugin(_ type: String, _ extra: String = "") -> String {
    "{\"type\":\"\(type)\",\"token\":\"abc\",\"seq\":3,\"file\":\"/tmp/a.md\"\(extra)}"
  }

  func testEveryEditorMessageKindDecodes() throws {
    let fixture = try buffersFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let envelope = PluginEnvelope(token: "abc", seq: 3, file: "/tmp/a.md")
    let parse = { (line: String) in parseEditorMessage(line, buffersDirectory: fixture.buffers) }
    XCTAssertEqual(
      parse(plugin("cursor", ",\"line\":7,\"top\":2,\"height\":30")),
      .cursor(envelope, line: 7, top: 2, height: 30))
    XCTAssertEqual(
      parse(plugin("buffer", ",\"text\":\"\(fixture.buffer.path)\"")),
      .buffer(envelope, text: URL(fileURLWithPath: canonicalPath(fixture.buffer.path))))
    XCTAssertEqual(parse(plugin("clean")), .clean(envelope))
    XCTAssertEqual(parse(plugin("follow")), .follow(envelope))
    XCTAssertEqual(parse(plugin("unlinked")), .unlinked(envelope))
    XCTAssertEqual(parse(plugin("exit")), .exit(envelope))
    XCTAssertEqual(parse(#"{"type":"edit","mode":"configured","line":12}"#), .edit(mode: .configured, line: 12))
    XCTAssertEqual(parse(#"{"type":"edit","mode":"alternate","line":1}"#), .edit(mode: .alternate, line: 1))
    XCTAssertEqual(envelope, EditorMessage.follow(envelope).envelope)
    XCTAssertNil(EditorMessage.edit(mode: .configured, line: 1).envelope)
  }

  func testControlCommandsRoundTrip() {
    let link = EditorControlCommand.link(socket: "/tmp/v/a b.sock", token: "t0", file: "/tmp/a \"q\".md", line: 4)
    let jump = EditorControlCommand.jump(token: "t0", line: 9)
    for command in [link, jump] {
      XCTAssertFalse(command.wireLine.contains("\n"))
      XCTAssertEqual(EditorControlCommand.parse(command.wireLine), command)
    }
    XCTAssertEqual(
      jump.wireLine, #"{"line":9,"token":"t0","type":"jump"}"#)
    XCTAssertEqual(
      EditorMessage.editLine(mode: .alternate, line: 3), #"{"line":3,"mode":"alternate","type":"edit"}"#)
  }

  func testRequiredFieldsAreEnforced() throws {
    let fixture = try buffersFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let parse = { (line: String) in parseEditorMessage(line, buffersDirectory: fixture.buffers) }
    let bad = [
      "{}", #"{"type":"nope"}"#, #"{"type":"follow"}"#,
      #"{"type":"follow","token":"","seq":1,"file":"/tmp/a.md"}"#,
      #"{"type":"follow","token":"t","seq":-1,"file":"/tmp/a.md"}"#,
      #"{"type":"follow","token":"t","seq":"1","file":"/tmp/a.md"}"#,
      #"{"type":"follow","token":"t","seq":1,"file":"a.md"}"#,
      #"{"type":"follow","token":5,"seq":1,"file":"/tmp/a.md"}"#,
      plugin("cursor"), plugin("cursor", ",\"line\":0,\"top\":1,\"height\":5"),
      plugin("cursor", ",\"line\":1,\"top\":1,\"height\":0"),
      plugin("cursor", ",\"line\":null,\"top\":1,\"height\":5"),
      plugin("buffer"),
      #"{"type":"edit","mode":"configured"}"#, #"{"type":"edit","mode":"split","line":1}"#,
      #"{"type":"edit","mode":"configured","line":0}"#, #"{"type":"edit","line":1}"#,
      "not json", "{",
    ]
    for line in bad { XCTAssertNil(parse(line), line) }
    for line in [
      "{}", #"{"type":"link","token":"t","file":"/tmp/a.md","line":1}"#,
      #"{"type":"link","socket":"s.sock","token":"t","file":"/tmp/a.md","line":1}"#,
      #"{"type":"jump","token":"t"}"#, #"{"type":"jump","line":2}"#, #"{"type":"jump","token":"t","line":null}"#,
      #"{"type":"cursor","token":"t","line":1}"#,
    ] {
      XCTAssertNil(EditorControlCommand.parse(line), line)
    }
  }

  func testBufferPathsMustBeRegularFilesInsideTheBuffersDirectory() throws {
    let fixture = try buffersFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let outside = fixture.root.appendingPathComponent("outside.md")
    try "# o".write(to: outside, atomically: true, encoding: .utf8)
    let link = fixture.buffers.appendingPathComponent("link.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let directory = fixture.buffers.appendingPathComponent("dir.md", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let escape = fixture.buffers.path + "/../outside.md"
    let parse = { (path: String) in
      parseEditorMessage(self.plugin("buffer", ",\"text\":\"\(path)\""), buffersDirectory: fixture.buffers)
    }
    XCTAssertNotNil(parse(fixture.buffer.path))
    for path in [outside.path, link.path, directory.path, escape, "relative.md", fixture.buffers.path + "/missing.md"] {
      XCTAssertNil(parse(path), path)
    }
    XCTAssertNil(parseEditorMessage(plugin("buffer", ",\"text\":\"\(fixture.buffer.path)\""), buffersDirectory: nil))
  }

  func testTheServerRoutesEditorMessagesAndKeepsLegacyLines() throws {
    let fixture = try buffersFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let sock = fixture.root.appendingPathComponent("e.sock")
    let lock = NSLock()
    nonisolated(unsafe) var received: [EditorMessage] = []
    let got = expectation(description: "editor")
    got.expectedFulfillmentCount = 2
    let opened = expectation(description: "open")
    let legacy = fixture.root.appendingPathComponent("legacy.md")
    try "# l".write(to: legacy, atomically: true, encoding: .utf8)
    let server = try ViewerSocketServer(
      socket: sock, buffersDirectory: fixture.buffers,
      onOpen: { url in
        XCTAssertEqual(url.path, legacy.path)
        opened.fulfill()
      },
      onEditor: { message in
        lock.withLock { received.append(message) }
        got.fulfill()
      })
    defer { server.close() }
    XCTAssertTrue(ViewerSocketClient.sendLine(plugin("follow"), to: sock))
    XCTAssertTrue(ViewerSocketClient.sendEdit(mode: .alternate, line: 5, to: sock))
    XCTAssertTrue(ViewerSocketClient.sendLine(#"{"type":"bogus"}"#, to: sock))
    XCTAssertTrue(ViewerSocketClient.send(path: legacy.path, to: sock))
    wait(for: [got, opened], timeout: 2)
    XCTAssertEqual(
      lock.withLock { received },
      [.follow(PluginEnvelope(token: "abc", seq: 3, file: "/tmp/a.md")), .edit(mode: .alternate, line: 5)])
  }

  func testTheMessageSizeLimitCoversEditorMessages() throws {
    let padded = plugin("follow").dropLast() + ",\"pad\":\"" + String(repeating: "a", count: 4100) + "\"}"
    XCTAssertNil(parseEditorMessage(String(padded), buffersDirectory: nil))
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sock = dir.appendingPathComponent("l.sock")
    let server = try ViewerSocketServer(socket: sock) { _ in }
    defer { server.close() }
    XCTAssertFalse(ViewerSocketClient.sendLine(String(padded), to: sock))
  }

  func testRefusedConnectsKeepTheSocketFileWhenAskedTo() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let stale = dir.appendingPathComponent("stale.sock")
    var address = try XCTUnwrap(socketAddress(path: stale.path))
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    Darwin.close(fd)
    XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
    XCTAssertFalse(ViewerSocketClient.send(.jump(token: "t", line: 1), to: stale))
    XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
    XCTAssertFalse(ViewerSocketClient.sendLine("x", to: stale, unlinkOnRefused: false))
    XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
    XCTAssertFalse(ViewerSocketClient.sendLine("x", to: stale))
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))

    let plain = dir.appendingPathComponent("plain.sock")
    FileManager.default.createFile(atPath: plain.path, contents: nil)
    XCTAssertFalse(ViewerSocketClient.sendLine("x", to: plain, unlinkOnRefused: false))
    XCTAssertTrue(FileManager.default.fileExists(atPath: plain.path))
  }
}
