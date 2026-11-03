import Darwin
import XCTest

@testable import MDViewerCore

final class HandoffSpawnTests: XCTestCase {
  struct Pipe {
    let read: Int32
    let write: Int32

    init() throws {
      var descriptors: [Int32] = [0, 0]
      guard pipe(&descriptors) == 0 else { throw POSIXError(.EMFILE) }
      read = descriptors[0]
      write = descriptors[1]
    }

    func drain() -> String {
      close(write)
      defer { close(read) }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = Darwin.read(read, &buffer, buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer[0..<count])
      }
      return String(decoding: data, as: UTF8.self)
    }
  }

  func run(
    _ command: [String], environment: [String: String] = [:], directory: URL? = nil
  ) throws -> (status: Int32, output: String) {
    let output = try Pipe()
    let pid = try HandoffSpawn.spawn(
      command, environment: environment, directory: directory,
      standardIO: [STDIN_FILENO, output.write, output.write])
    let text = output.drain()
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return (HandoffChild.exitCode(status), text)
  }

  func testTheChildGetsDefaultSignalsAndAnEmptyMaskEvenWhenTheParentIgnoresThem() throws {
    let previous = signal(SIGINT, SIG_IGN)
    var blocked = HandoffSpawn.signalSet([SIGINT])
    var saved = sigset_t()
    pthread_sigmask(SIG_BLOCK, &blocked, &saved)
    defer {
      pthread_sigmask(SIG_SETMASK, &saved, nil)
      signal(SIGINT, previous)
    }
    let result = try run(["/bin/sh", "-c", "kill -INT $$; echo survived"])
    XCTAssertEqual(result.status, 128 + SIGINT)
    XCTAssertEqual(result.output, "")
  }

  func testOnlyTheStandardDescriptorsAreInherited() throws {
    let directory = URL(fileURLWithPath: "/tmp/mdv-spawn-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = try XCTUnwrap(socketAddress(path: directory.appendingPathComponent("s.sock").path))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    XCTAssertEqual(listen(listener, 1), 0)
    let pipe = try Pipe()
    let held: [Int32] = [70, 71, 72]
    for (source, target) in zip([listener, pipe.read, pipe.write], held) {
      XCTAssertEqual(dup2(source, target), target)
      close(source)
      XCTAssertEqual(fcntl(target, F_GETFD) & FD_CLOEXEC, 0)
    }
    defer {
      for descriptor in held { close(descriptor) }
    }

    let result = try run(["/bin/ls", "/dev/fd"])
    XCTAssertEqual(result.status, 0)
    let listed = result.output.split(separator: "\n").compactMap { Int32($0) }
    XCTAssertEqual(Array(listed.prefix(3)), [0, 1, 2])
    XCTAssertTrue(listed.dropFirst(3).allSatisfy { $0 > 2 && $0 < 10 }, "only ls's own descriptors: \(listed)")
    XCTAssertTrue(Set(listed).isDisjoint(with: held))
  }

  func testTheChildStaysInTheParentProcessGroup() throws {
    let pid = try HandoffSpawn.spawn(["/bin/sleep", "5"], environment: [:], directory: nil)
    XCTAssertEqual(getpgid(pid), getpgrp())
    kill(pid, SIGKILL)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
  }

  func testTheChildGetsTheProvidedEnvironmentAndFolderWithNoShellWrapper() throws {
    let result = try run(["/usr/bin/env"], environment: ["MARK": "launched", "PATH": "/usr/bin"])
    XCTAssertEqual(result.output, "MARK=launched\nPATH=/usr/bin\n")

    let folder = URL(fileURLWithPath: "/usr/share")
    XCTAssertEqual(try run(["/bin/pwd"], directory: folder).output, "/usr/share\n")
  }

  func testARelativeExecutableIsRejected() {
    XCTAssertThrowsError(try HandoffSpawn.spawn(["nvim"], environment: [:], directory: nil))
  }

  func testAStoppedChildGetsSIGCONT() throws {
    let output = try Pipe()
    let pid = try HandoffSpawn.spawn(
      ["/bin/sh", "-c", "kill -STOP $$; echo resumed"], environment: [:], directory: nil,
      standardIO: [STDIN_FILENO, output.write, output.write])
    let exited = expectation(description: "exit")
    var code: Int32?
    let child = HandoffChild(pid: pid) { status in
      code = status
      exited.fulfill()
    }
    wait(for: [exited], timeout: 5)
    XCTAssertEqual(child.pid, pid)
    XCTAssertEqual(code, 0)
    XCTAssertEqual(output.drain(), "resumed\n")
  }

  func testExitCodesIncludeSignals() {
    XCTAssertEqual(HandoffChild.exitCode(0), 0)
    XCTAssertEqual(HandoffChild.exitCode(3 << 8), 3)
    XCTAssertEqual(HandoffChild.exitCode(SIGKILL), 128 + SIGKILL)
  }

  func testTheRestoreSequenceSplitsIntoModesAndScreen() {
    XCTAssertEqual(TerminalSequences.restoreModes + TerminalSequences.restoreScreen, TerminalSequences.restore)
    XCTAssertEqual(TerminalSequences.restoreScreen, "\u{1b}[?1049l")
    XCTAssertFalse(TerminalSequences.restoreModes.contains("\u{1b}[?1049l"))
    XCTAssertTrue(TerminalSequences.restoreModes.hasSuffix(Kitty.deleteAll()))
  }
}
