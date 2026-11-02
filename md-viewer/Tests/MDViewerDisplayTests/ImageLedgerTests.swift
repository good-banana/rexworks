import XCTest

@testable import MDViewerDisplay

final class ImageLedgerTests: XCTestCase {
  func testIDsAreUniqueAndNonZero() {
    var ledger = ImageLedger(firstID: 0)
    let a = ledger.allocate()
    let b = ledger.allocate()
    XCTAssertEqual(a, 1)
    XCTAssertEqual(b, 2)
    XCTAssertEqual(ledger.live, [1, 2])
    XCTAssertEqual(ledger.pending, 2)
  }

  func testFirstIDIsDerivedFromProcessAndBelowFenceRange() {
    XCTAssertEqual(ImageLedger.firstID(processID: 3), 3 << 16 | 1)
    XCTAssertLessThan(ImageLedger.firstID(processID: Int32.max), FenceIDs.base)
    XCTAssertNotEqual(ImageLedger.firstID(processID: 100), ImageLedger.firstID(processID: 101))
  }

  func testConfirmRetiresEveryOtherImage() {
    var ledger = ImageLedger(firstID: 10)
    let first = ledger.allocate()
    XCTAssertEqual(ledger.confirm(first), [])
    XCTAssertEqual(ledger.displayed, first)
    let second = ledger.allocate()
    XCTAssertEqual(ledger.displayed, first)
    XCTAssertEqual(ledger.confirm(second), [first])
    XCTAssertEqual(ledger.live, [second])
    XCTAssertNil(ledger.pending)
    XCTAssertEqual(ledger.confirm(999), [])
  }

  func testDiscardKeepsTheDisplayedImage() {
    var ledger = ImageLedger(firstID: 10)
    let first = ledger.allocate()
    _ = ledger.confirm(first)
    let failed = ledger.allocate()
    ledger.discard(failed)
    XCTAssertEqual(ledger.displayed, first)
    XCTAssertEqual(ledger.live, [first])
    XCTAssertNil(ledger.pending)
  }

  func testWrapSkipsLiveIDsAndFenceRange() {
    var ledger = ImageLedger(firstID: 1)
    _ = ledger.confirm(ledger.allocate())
    ledger.next = FenceIDs.base - 1
    let last = ledger.allocate()
    XCTAssertEqual(last, FenceIDs.base - 1)
    XCTAssertEqual(ledger.allocate(), 2)
  }

  func testLongSessionKeepsAtMostTwoLiveImages() {
    var ledger = ImageLedger(firstID: 1)
    var retired = 0
    for _ in 0..<10_000 {
      let id = ledger.allocate()
      XCTAssertLessThanOrEqual(ledger.live.count, 2)
      retired += ledger.confirm(id).count
    }
    XCTAssertEqual(retired, 9_999)
    XCTAssertEqual(ledger.live.count, 1)
  }

  func testRemoveAllReturnsEveryLiveImage() {
    var ledger = ImageLedger(firstID: 5)
    _ = ledger.confirm(ledger.allocate())
    _ = ledger.allocate()
    XCTAssertEqual(ledger.removeAll(), [5, 6])
    XCTAssertTrue(ledger.live.isEmpty)
    XCTAssertNil(ledger.displayed)
  }

  func testFenceIDsWrapInsideTheirRange() {
    var fences = FenceIDs()
    XCTAssertEqual(fences.allocate(), FenceIDs.base)
    XCTAssertEqual(fences.allocate(), FenceIDs.base + 1)
  }

  func testConfirmingAnOlderFrameKeepsNewerUnsettledFrames() {
    var ledger = ImageLedger(firstID: 1)
    _ = ledger.confirm(ledger.allocate())
    let older = ledger.allocate()
    let newer = ledger.allocate()
    XCTAssertEqual(ledger.unsettled, [older, newer])
    XCTAssertEqual(ledger.newest, newer)
    XCTAssertEqual(ledger.confirm(older), [1])
    XCTAssertEqual(ledger.live, [older, newer])
    XCTAssertEqual(ledger.unsettled, [newer])
    XCTAssertEqual(ledger.confirm(newer), [older])
    XCTAssertEqual(ledger.newest, newer)
  }
}
