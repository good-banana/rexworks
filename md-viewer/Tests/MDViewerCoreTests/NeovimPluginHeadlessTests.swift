import Foundation
import XCTest

@testable import MDViewerCore

final class NeovimPluginHeadlessTests: XCTestCase {
  private static let nvim: String? = {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let directories = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
    return directories.map { "\($0)/nvim" }.first { FileManager.default.isExecutableFile(atPath: $0) }
  }()
  private static let timeout: TimeInterval = 10

  private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [EditorMessage] = []

    var messages: [EditorMessage] { lock.withLock { received } }
    func add(_ message: EditorMessage) { lock.withLock { received.append(message) } }
  }

  private struct Session {
    var directory: URL
    var file: URL
    var other: URL
    var preview: URL
    var control: URL
    var listen: URL
    var marker: URL
    var inbox: Inbox
    var server: ViewerSocketServer
    var process: Process
  }

  private func wait(_ what: String, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(Self.timeout)
    while !condition() {
      guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  private func start() throws -> Session {
    guard let nvim = Self.nvim else { throw XCTSkip("nvim is not installed") }
    let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("mdv-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let paths = SupportPaths(home: directory.appendingPathComponent("home"))
    try NeovimPlugin.install(paths)
    let file = directory.appendingPathComponent("a.md")
    try Data((1...100).map { "line \($0)\n" }.joined().utf8).write(to: file)
    let other = directory.appendingPathComponent("b.md")
    try Data("other\n".utf8).write(to: other)
    let preview = directory.appendingPathComponent("p.sock")
    let inbox = Inbox()
    let buffers = directory.appendingPathComponent("buffers")
    let server = try ViewerSocketServer(
      socket: preview, buffersDirectory: buffers, onOpen: { _ in }, onEditor: { inbox.add($0) })
    let control = directory.appendingPathComponent("c.sock")
    let listen = directory.appendingPathComponent("l.sock")
    let marker = directory.appendingPathComponent("go")
    let gate =
      "lua vim.wait(\(Int(Self.timeout * 1000)), function() return vim.uv.fs_stat('\(marker.path)') ~= nil end, 10)"
      + " vim.wait(300)"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: nvim)
    process.arguments = [
      "--headless", "-u", "NONE", "-i", "NONE", "-n", "--listen", listen.path,
      "--cmd", "lua dofile(os.getenv('MD_VIEWER_PLUGIN'))", "-c", "lua MdViewer.ensure()", "-c", gate, file.path,
    ]
    process.environment = ProcessInfo.processInfo.environment.merging([
      "MD_VIEWER_SOCKET": preview.path, "MD_VIEWER_TOKEN": "A", "MD_VIEWER_CONTROL": control.path,
      "MD_VIEWER_FILES": directory.appendingPathComponent("files").path,
      "MD_VIEWER_BUFFERS": buffers.path,
      "MD_VIEWER_PLUGIN": paths.neovimPlugin.path,
    ]) { $1 }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let session = Session(
      directory: directory, file: file, other: other, preview: preview, control: control, listen: listen,
      marker: marker, inbox: inbox, server: server, process: process)
    addTeardownBlock {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      server.close()
      try? FileManager.default.removeItem(at: directory)
    }
    wait("the control socket") { FileManager.default.fileExists(atPath: control.path) }
    return session
  }

  private func send(_ command: EditorControlCommand, _ session: Session) {
    XCTAssertTrue(ViewerSocketClient.send(command, to: session.control))
  }

  @discardableResult
  private func remote(_ arguments: [String], _ session: Session) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: try XCTUnwrap(Self.nvim))
    process.arguments = ["--server", session.listen.path] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    wait("nvim --server") { !process.isRunning }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      return ""
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func summary(_ messages: [EditorMessage]) -> [String] {
    messages.map { message in
      guard let envelope = message.envelope else { return "edit" }
      let kind =
        switch message {
        case .cursor(_, let line, _, _): "cursor \(line)"
        case .buffer: "buffer"
        case .clean: "clean"
        case .follow: "follow"
        case .unlinked: "unlinked"
        case .exit: "exit"
        case .edit: "edit"
        }
      return "\(envelope.token) \(kind) \(URL(fileURLWithPath: envelope.file).lastPathComponent)"
    }
  }

  func testLinkAndJumpWaitForStartupThenRunInOrderAndNothingRunsAfterQuit() throws {
    let session = try start()
    send(.link(socket: session.preview.path, token: "B", file: session.file.path, line: 5), session)
    send(.jump(token: "B", line: 40), session)
    send(.jump(token: "A", line: 60), session)
    FileManager.default.createFile(atPath: session.marker.path, contents: nil)

    wait("the jump") { summary(session.inbox.messages).contains("B cursor 40 a.md") }
    XCTAssertEqual(try remote(["--remote-expr", "line('.')"], session), "40")
    let received = summary(session.inbox.messages)
    let firstB = try XCTUnwrap(received.firstIndex { $0.hasPrefix("B ") })
    let lastA = try XCTUnwrap(received.lastIndex { $0.hasPrefix("A ") })
    XCTAssertLessThan(lastA, firstB, "\(received)")
    XCTAssertEqual(received.filter { $0 == "A follow a.md" }.count, 2, "BufEnter and VimEnter run under A: \(received)")
    XCTAssertEqual(Array(received[firstB..<firstB + 3]), ["B follow a.md", "B clean a.md", "B cursor 5 a.md"])
    XCTAssertFalse(received.contains("A cursor 60 a.md"), "a jump under the replaced token is ignored")

    try remote(["--remote-send", ":"], session)
    wait("command-line mode") { (try? remote(["--remote-expr", "mode()"], session)) == "c" }
    send(.link(socket: session.preview.path, token: "C", file: session.other.path, line: 1), session)
    try remote(["--remote-send", "qa!<CR>"], session)
    wait("Neovim to quit") { !session.process.isRunning }
    wait("the exit message") { summary(session.inbox.messages).contains("B exit a.md") }
    Thread.sleep(forTimeInterval: 0.2)
    let afterQuit = summary(session.inbox.messages)
    XCTAssertFalse(afterQuit.contains { $0.hasPrefix("C ") }, "\(afterQuit)")
    XCTAssertEqual(afterQuit.last, "B exit a.md")
  }

  func testASaveSendsCleanBeforeLaterCommands() throws {
    let session = try start()
    FileManager.default.createFile(atPath: session.marker.path, contents: nil)
    wait("the VimEnter snapshot") { summary(session.inbox.messages).filter { $0 == "A follow a.md" }.count == 2 }
    try remote(["--remote-expr", "execute('call setline(1, \"changed\")')"], session)
    wait("the unsaved buffer") { summary(session.inbox.messages).contains("A buffer a.md") }
    try remote(["--remote-expr", "execute('write')"], session)
    send(.link(socket: session.preview.path, token: "B", file: session.file.path, line: 1), session)
    wait("the relink") { summary(session.inbox.messages).contains("B follow a.md") }
    let received = summary(session.inbox.messages)
    let saved = try XCTUnwrap(received.lastIndex(of: "A clean a.md"), "\(received)")
    let relinked = try XCTUnwrap(received.firstIndex(of: "B follow a.md"))
    XCTAssertLessThan(saved, relinked, "clean goes out on BufWritePost, not after a debounce: \(received)")
    XCTAssertGreaterThan(saved, try XCTUnwrap(received.lastIndex(of: "A buffer a.md")))
  }
}
