import XCTest

@testable import MDViewerDisplay

final class FramePacerTests: XCTestCase {
  func testFirstFrameSendsImmediately() {
    let pacer = FramePacer()
    XCTAssertTrue(pacer.canSend(at: 0))
    XCTAssertEqual(pacer.earliestSend(after: 5), 5)
  }

  func testOnlyOneFrameInFlight() {
    var pacer = FramePacer()
    pacer.sent(fence: 1, stagedThrough: 3, at: 0)
    XCTAssertFalse(pacer.canSend(at: 100 * ms))
    XCTAssertNil(pacer.acknowledge(2))
    XCTAssertEqual(pacer.acknowledge(1)?.stagedThrough, 3)
    XCTAssertTrue(pacer.canSend(at: 100 * ms))
  }

  func testAtMostSixtyFramesPerSecond() {
    var pacer = FramePacer()
    pacer.sent(fence: 1, stagedThrough: nil, at: 0)
    _ = pacer.acknowledge(1)
    XCTAssertFalse(pacer.canSend(at: 16 * ms))
    XCTAssertEqual(pacer.earliestSend(after: 2 * ms), FramePacer.sixtyHertz)
    XCTAssertTrue(pacer.canSend(at: FramePacer.sixtyHertz))
  }

  func testFenceTimeoutReleasesTheSlot() {
    var pacer = FramePacer(fenceTimeout: 100 * ms)
    pacer.sent(fence: 1, stagedThrough: nil, at: 0)
    XCTAssertEqual(pacer.earliestSend(after: 0), 100 * ms)
    XCTAssertNil(pacer.expire(at: 99 * ms))
    XCTAssertEqual(pacer.expire(at: 100 * ms)?.fence, 1)
    XCTAssertTrue(pacer.canSend(at: 100 * ms))
    XCTAssertNil(pacer.acknowledge(1))
  }
}
