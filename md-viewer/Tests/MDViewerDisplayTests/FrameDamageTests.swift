import XCTest

@testable import MDViewerDisplay

final class FrameDamageTests: XCTestCase {
  let frame = PixelRect(x: 0, y: 0, width: 1000, height: 1000)

  func testEmptyPlansNothing() {
    XCTAssertEqual(FrameDamage().plan(in: frame), .none)
    XCTAssertTrue(FrameDamage().isEmpty)
  }

  func testOverlappingAndTouchingRectsCoalesce() {
    var damage = FrameDamage()
    damage.invalidate(PixelRect(x: 0, y: 0, width: 100, height: 10))
    damage.invalidate(PixelRect(x: 0, y: 10, width: 100, height: 10))
    damage.invalidate(PixelRect(x: 50, y: 5, width: 100, height: 10))
    XCTAssertEqual(damage.plan(in: frame), .patches([PixelRect(x: 0, y: 0, width: 150, height: 20)]))
  }

  func testChainedMergeAbsorbsEarlierRects() {
    var damage = FrameDamage()
    damage.invalidate(PixelRect(x: 0, y: 0, width: 10, height: 10))
    damage.invalidate(PixelRect(x: 100, y: 0, width: 10, height: 10))
    damage.invalidate(PixelRect(x: 5, y: 0, width: 100, height: 10))
    XCTAssertEqual(damage.rects, [PixelRect(x: 0, y: 0, width: 110, height: 10)])
  }

  func testDisjointRectsStaySeparate() {
    var damage = FrameDamage()
    damage.invalidate(PixelRect(x: 0, y: 0, width: 100, height: 10))
    damage.invalidate(PixelRect(x: 0, y: 500, width: 100, height: 10))
    XCTAssertEqual(
      damage.plan(in: frame),
      .patches([PixelRect(x: 0, y: 0, width: 100, height: 10), PixelRect(x: 0, y: 500, width: 100, height: 10)]))
  }

  func testRectsAreClippedToFrame() {
    var damage = FrameDamage()
    damage.invalidate(PixelRect(x: 900, y: 990, width: 300, height: 30))
    damage.invalidate(PixelRect(x: 0, y: 2000, width: 10, height: 10))
    XCTAssertEqual(damage.plan(in: frame), .patches([PixelRect(x: 900, y: 990, width: 100, height: 10)]))
  }

  func testAreaAboveFortyPercentSendsFullFrame() {
    var damage = FrameDamage()
    damage.invalidate(PixelRect(x: 0, y: 0, width: 1000, height: 400))
    XCTAssertEqual(damage.plan(in: frame), .patches([PixelRect(x: 0, y: 0, width: 1000, height: 400)]))
    damage.invalidate(PixelRect(x: 0, y: 900, width: 1000, height: 1))
    XCTAssertEqual(damage.plan(in: frame), .full)
  }

  func testTooManyRectsCollapseToBoundingRect() {
    var damage = FrameDamage()
    for index in 0...FrameDamage.maximumPatches {
      damage.invalidate(PixelRect(x: 0, y: index * 20, width: 10, height: 5))
    }
    XCTAssertEqual(damage.rects, [PixelRect(x: 0, y: 0, width: 10, height: 165)])
  }

  func testFullInvalidationWinsAndResets() {
    var damage = FrameDamage()
    damage.invalidateAll()
    damage.invalidate(PixelRect(x: 0, y: 0, width: 10, height: 10))
    XCTAssertEqual(damage.plan(in: frame), .full)
    XCTAssertTrue(damage.rects.isEmpty)
    damage.reset()
    XCTAssertTrue(damage.isEmpty)
    damage.invalidate(PixelRect(x: 0, y: 0, width: 0, height: 10))
    XCTAssertTrue(damage.isEmpty)
  }

  let content = PixelRect(x: 0, y: 0, width: 1000, height: 900)
  let status = PixelRect(x: 0, y: 900, width: 1000, height: 100)

  func testScrollDownExposesTheBottomStripAndStatusBar() {
    var damage = FrameDamage()
    damage.scroll(by: 60, content: content, statusBar: status)
    XCTAssertEqual(damage.scrollShift, 60)
    XCTAssertEqual(damage.plan(in: frame), .scroll(60, [PixelRect(x: 0, y: 840, width: 1000, height: 160)]))
  }

  func testScrollUpExposesTheTopStrip() {
    var damage = FrameDamage()
    damage.scroll(by: -30, content: content, statusBar: status)
    XCTAssertEqual(
      damage.plan(in: frame),
      .scroll(-30, [PixelRect(x: 0, y: 0, width: 1000, height: 30), PixelRect(x: 0, y: 900, width: 1000, height: 100)]))
  }

  func testPendingRectsMoveWithTheContent() {
    var damage = FrameDamage()
    damage.invalidate(PixelRect(x: 10, y: 400, width: 50, height: 20))
    damage.invalidate(PixelRect(x: 10, y: 10, width: 50, height: 20))
    damage.scroll(by: 30, content: content, statusBar: status)
    XCTAssertEqual(
      damage.rects,
      [
        PixelRect(x: 10, y: 370, width: 50, height: 20), PixelRect(x: 0, y: 870, width: 1000, height: 130),
      ])
  }

  func testStatusBarDamageDoesNotMoveWithTheContent() {
    var damage = FrameDamage()
    damage.invalidate(PixelRect(x: 0, y: 880, width: 1000, height: 120))
    damage.scroll(by: -30, content: content, statusBar: status)
    XCTAssertEqual(
      Set(damage.rects),
      [PixelRect(x: 0, y: 0, width: 1000, height: 30), PixelRect(x: 0, y: 900, width: 1000, height: 100)])
  }

  func testScrollsAccumulateAndCancel() {
    var damage = FrameDamage()
    damage.scroll(by: 30, content: content, statusBar: status)
    damage.scroll(by: -30, content: content, statusBar: status)
    XCTAssertEqual(damage.scrollShift, 0)
    XCTAssertFalse(damage.isEmpty)
    guard case .patches = damage.plan(in: frame) else { return XCTFail("expected patches") }
  }

  func testLargeScrollsSendAFullFrame() {
    var damage = FrameDamage()
    damage.scroll(by: 300, content: content, statusBar: status)
    XCTAssertEqual(damage.plan(in: frame), .scroll(300, [PixelRect(x: 0, y: 600, width: 1000, height: 400)]))
    damage.scroll(by: 10, content: content, statusBar: status)
    XCTAssertEqual(damage.plan(in: frame), .full)
    var far = FrameDamage()
    far.scroll(by: 600, content: content, statusBar: status)
    far.scroll(by: 600, content: content, statusBar: status)
    XCTAssertTrue(far.needsFullFrame)
    XCTAssertEqual(far.scrollShift, 0)
  }

  func testScrollAfterFullInvalidationStaysFull() {
    var damage = FrameDamage()
    damage.invalidateAll()
    damage.scroll(by: 30, content: content, statusBar: status)
    XCTAssertEqual(damage.plan(in: frame), .full)
    damage.reset()
    XCTAssertEqual(damage.scrollShift, 0)
  }

  func testRectSubtraction() {
    let rect = PixelRect(x: 0, y: 0, width: 100, height: 100)
    XCTAssertEqual(rect.subtracting(PixelRect(x: 200, y: 0, width: 10, height: 10)), [rect])
    XCTAssertEqual(rect.subtracting(rect), [])
    XCTAssertEqual(
      rect.subtracting(PixelRect(x: 0, y: 80, width: 100, height: 50)), [PixelRect(x: 0, y: 0, width: 100, height: 80)])
    XCTAssertEqual(
      Set(rect.subtracting(PixelRect(x: 40, y: 40, width: 20, height: 20))),
      [
        PixelRect(x: 0, y: 0, width: 100, height: 40), PixelRect(x: 0, y: 60, width: 100, height: 40),
        PixelRect(x: 0, y: 40, width: 40, height: 20), PixelRect(x: 60, y: 40, width: 40, height: 20),
      ])
  }
}
