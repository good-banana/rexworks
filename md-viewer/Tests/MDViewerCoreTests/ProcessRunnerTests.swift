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
}
