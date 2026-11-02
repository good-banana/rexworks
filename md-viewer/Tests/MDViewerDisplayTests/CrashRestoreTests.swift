import Darwin
import Foundation
import MDViewerCore
import XCTest

final class CrashRestoreTests: XCTestCase {
  private var probe: URL {
    Bundle(for: CrashRestoreTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mdv-crash-probe")
  }

  private func crash(_ signal: Int32, disarm: Bool = false) throws -> (output: Data, signal: Int32?) {
    var ends: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&ends), 0)
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, ends[1], STDOUT_FILENO)
    posix_spawn_file_actions_addclose(&actions, ends[0])
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setexceptionports_np(
      &attributes,
      exception_mask_t(
        EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_SOFTWARE | EXC_MASK_BREAKPOINT
          | EXC_MASK_CRASH), mach_port_t(MACH_PORT_NULL), EXCEPTION_DEFAULT, THREAD_STATE_NONE)
    let arguments = [probe.path, String(signal), disarm ? "disarm" : "armed", TerminalSequences.restore]
    var argv = arguments.map { strdup($0) } + [nil]
    defer {
      for argument in argv { free(argument) }
    }
    var child: pid_t = 0
    let spawned = posix_spawn(&child, probe.path, &actions, &attributes, &argv, environ)
    close(ends[1])
    guard spawned == 0 else {
      close(ends[0])
      throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO)
    }
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(ends[0], &buffer, buffer.count)
      if count <= 0 { break }
      received.append(contentsOf: buffer[0..<count])
    }
    close(ends[0])
    var status: Int32 = 0
    waitpid(child, &status, 0)
    let terminatingSignal = status & 0x7f
    return (received, terminatingSignal != 0 && terminatingSignal != 0x7f ? terminatingSignal : nil)
  }

  func testATrappingProcessWritesTheRestoreBytesAndDiesFromTheTrap() throws {
    let result = try crash(SIGTRAP)
    XCTAssertEqual(result.signal, SIGTRAP)
    XCTAssertEqual(result.output, Data(TerminalSequences.restore.utf8))
  }

  func testEveryCrashSignalRestores() throws {
    for signal in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
      let result = try crash(signal)
      XCTAssertNotNil(result.signal, "signal \(signal)")
      XCTAssertEqual(result.output, Data(TerminalSequences.restore.utf8), "signal \(signal)")
    }
  }

  func testDisarmedProcessWritesNothing() throws {
    let result = try crash(SIGABRT, disarm: true)
    XCTAssertEqual(result.signal, SIGABRT)
    XCTAssertTrue(result.output.isEmpty)
  }
}
