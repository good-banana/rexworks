import MDViewerCore
import XCTest

@testable import MDViewerDisplay

final class ResizeDebouncerTests: XCTestCase {
  let start = paneSize(columns: 100)

  func testSameSizeIsIgnored() {
    var debouncer = ResizeDebouncer(displayed: start)
    XCTAssertNil(debouncer.observe(start, at: 0))
    XCTAssertFalse(debouncer.isHolding)
    XCTAssertNil(debouncer.fire(at: 1_000 * ms))
  }

  func testFirstChangeHoldsThenSettlesAfterQuietPeriod() {
    var debouncer = ResizeDebouncer(displayed: start)
    let next = paneSize(columns: 80)
    XCTAssertEqual(debouncer.observe(next, at: 10 * ms), .hold)
    XCTAssertTrue(debouncer.isHolding)
    XCTAssertEqual(debouncer.deadline, 90 * ms)
    XCTAssertNil(debouncer.fire(at: 89 * ms))
    XCTAssertEqual(debouncer.fire(at: 90 * ms), .settle(next))
    XCTAssertFalse(debouncer.isHolding)
    XCTAssertEqual(debouncer.displayed, next)
    XCTAssertNil(debouncer.fire(at: 200 * ms))
  }

  func testEveryNewSizeRestartsTheQuietPeriodAndOnlyTheLastSettles() {
    var debouncer = ResizeDebouncer(displayed: start)
    XCTAssertEqual(debouncer.observe(paneSize(columns: 90), at: 0), .hold)
    XCTAssertNil(debouncer.observe(paneSize(columns: 85), at: 50 * ms))
    XCTAssertNil(debouncer.observe(paneSize(columns: 85), at: 100 * ms))
    XCTAssertEqual(debouncer.deadline, 130 * ms)
    XCTAssertNil(debouncer.observe(paneSize(columns: 70), at: 120 * ms))
    XCTAssertNil(debouncer.fire(at: 130 * ms))
    XCTAssertEqual(debouncer.fire(at: 200 * ms), .settle(paneSize(columns: 70)))
  }

  func testReturningToTheDisplayedSizeStillSettles() {
    var debouncer = ResizeDebouncer(displayed: start)
    XCTAssertEqual(debouncer.observe(paneSize(columns: 90), at: 0), .hold)
    XCTAssertNil(debouncer.observe(start, at: 10 * ms))
    XCTAssertEqual(debouncer.fire(at: 90 * ms), .settle(start))
  }

  func testCustomSettleTime() {
    var debouncer = ResizeDebouncer(displayed: start, settleNanoseconds: 5 * ms)
    _ = debouncer.observe(paneSize(columns: 1), at: 0)
    XCTAssertEqual(debouncer.fire(at: 5 * ms), .settle(paneSize(columns: 1)))
  }

  func testResetCancelsAHold() {
    var debouncer = ResizeDebouncer(displayed: start)
    _ = debouncer.observe(paneSize(columns: 1), at: 0)
    debouncer.reset(displayed: paneSize(columns: 2))
    XCTAssertFalse(debouncer.isHolding)
    XCTAssertNil(debouncer.fire(at: 1_000 * ms))
    XCTAssertEqual(debouncer.displayed, paneSize(columns: 2))
  }
}
