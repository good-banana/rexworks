import CoreGraphics
import XCTest

@testable import MDViewerCore

final class ViewportTests: XCTestCase {
  func testClampsOffset() {
    var v = Viewport(pageHeight: 1000, viewHeight: 400, tileHeight: 400, offset: 0, cellHeight: 20)
    v.scroll(by: -50)
    XCTAssertEqual(v.offset, 0)
    v.scroll(by: 5000)
    XCTAssertEqual(v.offset, 600)
    XCTAssertEqual(v.percent, 100)
  }

  func testVisibleSlicesSpanTwoTiles() {
    let v = Viewport(pageHeight: 1000, viewHeight: 400, tileHeight: 400, offset: 300, cellHeight: 20)
    XCTAssertEqual(
      v.visibleTiles(),
      [
        TileSlice(index: 0, source: CGRect(x: 0, y: 300, width: 0, height: 100), destinationRow: 0, rows: 5),
        TileSlice(index: 1, source: CGRect(x: 0, y: 0, width: 0, height: 300), destinationRow: 5, rows: 15),
      ])
  }

  func testShortPageHasSingleSlice() {
    let v = Viewport(pageHeight: 150, viewHeight: 400, tileHeight: 400, offset: 0, cellHeight: 20)
    XCTAssertEqual(v.visibleTiles().count, 1)
  }

  func testShortPageSliceCoversWholeRows() {
    let v = Viewport(pageHeight: 150, viewHeight: 400, tileHeight: 400, offset: 0, cellHeight: 20)
    XCTAssertEqual(
      v.visibleTiles(),
      [TileSlice(index: 0, source: CGRect(x: 0, y: 0, width: 0, height: 160), destinationRow: 0, rows: 8)])
    XCTAssertEqual(v.percent, 100)
  }

  func testScrollSnapsToWholeRows() {
    var v = Viewport(pageHeight: 1000, viewHeight: 400, tileHeight: 400, offset: 0, cellHeight: 20)
    v.scroll(by: 31)
    XCTAssertEqual(v.offset, 40)
    v.scroll(to: 109)
    XCTAssertEqual(v.offset, 100)
    XCTAssertEqual(v.percent, 17)
  }

  func testMaximumOffsetRevealsPartialLastRow() {
    var v = Viewport(pageHeight: 1010, viewHeight: 400, tileHeight: 400, offset: 0, cellHeight: 20)
    v.scroll(to: .greatestFiniteMagnitude)
    XCTAssertEqual(v.offset, 620)
    XCTAssertEqual(v.percent, 100)
    let slices = v.visibleTiles()
    XCTAssertEqual(slices.map(\.index), [1, 2])
    XCTAssertEqual(slices.map(\.rows).reduce(0, +), 20)
  }

  func testOffsetRestoresFromFraction() {
    var v = Viewport(pageHeight: 2000, viewHeight: 400, tileHeight: 400, offset: 0, cellHeight: 20)
    v.scroll(to: 800)
    let fraction = v.fraction
    v.pageHeight = 4000
    v.scroll(toFraction: fraction)
    XCTAssertEqual(v.offset, 1800)
    XCTAssertEqual(v.tileCount, 10)
  }
}
