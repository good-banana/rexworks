import Darwin
import XCTest

@testable import MDViewerCore

final class ProcessRunnerTests: XCTestCase {
  func testCapturesStatusAndOutputWithoutShellExpansion() throws {
    let result = try ProcessRunner().run("/bin/echo", ["$(echo hi)", "a b"])
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "$(echo hi) a b\n")
  }

  func testReportsNonZeroStatusAndStderr() throws {
    let result = try ProcessRunner().run("/bin/ls", ["/definitely/missing"])
    XCTAssertNotEqual(result.status, 0)
    XCTAssertFalse(result.stderr.isEmpty)
  }

  func testTimesOut() {
    XCTAssertThrowsError(try ProcessRunner(timeout: 0.3).run("/bin/sleep", ["5"]))
  }

  func testPerCallTimeoutOverridesDefault() {
    let started = Date()
    XCTAssertThrowsError(try ProcessRunner(timeout: 30).run("/bin/sleep", ["5"], timeout: 0.2))
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
  }

  func testKillsChildThatIgnoresTerminate() {
    let started = Date()
    XCTAssertThrowsError(
      try ProcessRunner().run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.2))
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
  }

  func testMissingExecutableThrows() {
    XCTAssertThrowsError(try ProcessRunner().run("/no/such/binary", []))
  }

  func testReturnsOutputWhenAGrandchildHoldsStdoutOpen() throws {
    let started = Date()
    let result = try ProcessRunner(timeout: 10).run("/bin/sh", ["-c", "echo out; echo err >&2; sleep 5 & exit 3"])
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    XCTAssertEqual(result.status, 3)
    XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out\n")
    XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err\n")
  }

  func testHungChildIsKilledAtTheDeadlineAndTheCallThrows() {
    let started = Date()
    XCTAssertThrowsError(try ProcessRunner().run("/bin/sh", ["-c", "echo partial; sleep 30"], timeout: 0.3))
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
  }

  func testLargeOutputIsCapturedInFull() throws {
    let result = try ProcessRunner().run("/usr/bin/head", ["-c", "1000000", "/dev/zero"])
    XCTAssertEqual(result.stdout.count, 1_000_000)
  }

  func testNoReaderThreadStaysBlockedAcrossManyCalls() throws {
    let threads = try threadCount()
    let descriptors = openDescriptorCount()
    let started = Date()
    for _ in 0..<15 {
      _ = try ProcessRunner().run("/bin/sh", ["-c", "echo x; sleep 2 & exit 0"])
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    XCTAssertLessThanOrEqual(openDescriptorCount(), descriptors)
    XCTAssertLessThanOrEqual(try threadCount(), threads + 2)
  }

  private func openDescriptorCount() -> Int {
    (0..<Int32(getdtablesize())).filter { fcntl($0, F_GETFD) != -1 }.count
  }

  private func threadCount() throws -> Int {
    var list: thread_act_array_t?
    var count = mach_msg_type_number_t(0)
    XCTAssertEqual(task_threads(mach_task_self_, &list, &count), KERN_SUCCESS)
    if let list {
      vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
    }
    return Int(count)
  }
}
