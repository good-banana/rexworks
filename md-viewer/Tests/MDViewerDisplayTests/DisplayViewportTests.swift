import CoreGraphics
import MDViewerCore
import XCTest

@testable import MDViewerDisplay

final class DisplayViewportTests: XCTestCase {
  func testCellMetricsAndAreas() {
    let viewport = DisplayViewport(
      size: PaneSize(columns: 70, rows: 61, pixelWidth: 985, pixelHeight: 2013), statusRows: 1, pageHeight: 5000)
    XCTAssertEqual(viewport.cellWidth, 14)
    XCTAssertEqual(viewport.cellHeight, 33)
    XCTAssertEqual(viewport.frameWidth, 980)
    XCTAssertEqual(viewport.frameHeight, 2013)
    XCTAssertEqual(viewport.contentHeight, 1980)
    XCTAssertEqual(viewport.contentRect, PixelRect(x: 0, y: 0, width: 980, height: 1980))
    XCTAssertEqual(viewport.statusBarRect, PixelRect(x: 0, y: 1980, width: 980, height: 33))
    XCTAssertTrue(viewport.isDrawable)
  }

  func testStatusRowsFollowStatusBarHeight() {
    let tall = DisplayViewport(size: paneSize(cellHeight: 35), backingScale: 2, pageHeight: 100)
    XCTAssertEqual(tall.statusRows, 1)
    let small = DisplayViewport(size: paneSize(cellHeight: 16), backingScale: 2, pageHeight: 100)
    XCTAssertEqual(small.statusRows, 3)
    let none = DisplayViewport(size: paneSize(), backingScale: 2, pageHeight: 100, statusBar: false)
    XCTAssertEqual(none.statusRows, 0)
    let oneRow = DisplayViewport(size: paneSize(rows: 1), statusRows: 3, pageHeight: 100)
    XCTAssertEqual(oneRow.statusRows, 0)
  }

  func testScrollSnapsToWholeRowsAndClamps() {
    var viewport = DisplayViewport(size: paneSize(rows: 11, cellHeight: 30), statusRows: 1, pageHeight: 1000)
    XCTAssertEqual(viewport.contentHeight, 300)
    XCTAssertEqual(viewport.maximumOffset, 720)
    XCTAssertTrue(viewport.scroll(to: 44))
    XCTAssertEqual(viewport.offset, 30)
    viewport.scroll(to: 46)
    XCTAssertEqual(viewport.offset, 60)
    XCTAssertTrue(viewport.scroll(rows: 2))
    XCTAssertEqual(viewport.offset, 120)
    viewport.scroll(to: .greatestFiniteMagnitude)
    XCTAssertEqual(viewport.offset, 720)
    XCTAssertFalse(viewport.scroll(by: 10))
    viewport.scroll(to: -.infinity)
    XCTAssertEqual(viewport.offset, 0)
    viewport.scroll(to: .nan)
    XCTAssertEqual(viewport.offset, 0)
  }

  func testShortPageNeverScrolls() {
    var viewport = DisplayViewport(size: paneSize(), statusRows: 1, pageHeight: 100)
    XCTAssertEqual(viewport.maximumOffset, 0)
    XCTAssertFalse(viewport.scroll(to: 500))
  }

  func testPageHeightChangeReclamps() {
    var viewport = DisplayViewport(
      size: paneSize(rows: 11, cellHeight: 30), statusRows: 1, pageHeight: 1000, offset: 700)
    XCTAssertEqual(viewport.offset, 690)
    viewport.setPageHeight(500)
    XCTAssertEqual(viewport.offset, 210)
  }

  func testVisiblePageRectAndProgress() {
    let viewport = DisplayViewport(
      size: paneSize(rows: 11, cellHeight: 30), statusRows: 1, pageHeight: 1200, offset: 300)
    XCTAssertEqual(viewport.visiblePageRect, CGRect(x: 0, y: 300, width: 1600, height: 300))
    XCTAssertEqual(viewport.progress.start, 0.25)
    XCTAssertEqual(viewport.progress.fraction, 0.25)
  }

  func testPageAndPaneMapping() {
    let viewport = DisplayViewport(
      size: paneSize(rows: 11, cellHeight: 30), statusRows: 1, pageHeight: 1200, offset: 300)
    XCTAssertEqual(viewport.pagePoint(fromPane: CGPoint(x: 5, y: 10)), CGPoint(x: 5, y: 310))
    XCTAssertNil(viewport.pagePoint(fromPane: CGPoint(x: 5, y: 300)))
    XCTAssertNil(viewport.pagePoint(fromPane: CGPoint(x: -1, y: 0)))
    XCTAssertEqual(viewport.panePoint(fromPage: CGPoint(x: 5, y: 310)), CGPoint(x: 5, y: 10))
    XCTAssertEqual(
      viewport.paneRect(fromPage: CGRect(x: 10.5, y: 280, width: 20, height: 40.2)),
      PixelRect(x: 10, y: 0, width: 21, height: 21))
    XCTAssertNil(viewport.paneRect(fromPage: CGRect(x: 0, y: 700, width: 20, height: 20)))
    XCTAssertEqual(
      viewport.pageRect(fromPane: PixelRect(x: 0, y: 30, width: 100, height: 60)),
      CGRect(x: 0, y: 330, width: 100, height: 60))
  }

  func testCellMapping() {
    let viewport = DisplayViewport(
      size: paneSize(rows: 11, cellHeight: 30), statusRows: 1, pageHeight: 1200, offset: 300)
    XCTAssertEqual(viewport.cell(atPane: CGPoint(x: 33, y: 61)), CellPosition(column: 2, row: 2))
    XCTAssertNil(viewport.cell(atPane: CGPoint(x: 1600, y: 0)))
    XCTAssertNil(viewport.cell(atPane: CGPoint(x: 0, y: 330)))
    XCTAssertEqual(
      viewport.paneRect(of: CellPosition(column: 2, row: 3)), PixelRect(x: 32, y: 90, width: 16, height: 30))
    XCTAssertEqual(viewport.pagePoint(fromCell: CellPosition(column: 1, row: 1)), CGPoint(x: 16, y: 330))
    XCTAssertNil(viewport.pagePoint(fromCell: CellPosition(column: 1, row: 10)))
  }

  func testZeroPixelSizeIsNotDrawable() {
    let viewport = DisplayViewport(
      size: PaneSize(columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0), statusRows: 1, pageHeight: 100)
    XCTAssertFalse(viewport.isDrawable)
    XCTAssertEqual(viewport.maximumOffset, 0)
  }

  func testPixelRectGeometry() {
    let a = PixelRect(x: 0, y: 0, width: 10, height: 10)
    XCTAssertTrue(a.touches(PixelRect(x: 10, y: 0, width: 5, height: 5)))
    XCTAssertFalse(a.touches(PixelRect(x: 11, y: 0, width: 5, height: 5)))
    XCTAssertNil(a.intersection(PixelRect(x: 10, y: 0, width: 5, height: 5)))
    XCTAssertEqual(a.union(PixelRect(x: 20, y: 5, width: 5, height: 10)), PixelRect(x: 0, y: 0, width: 25, height: 15))
    XCTAssertEqual(
      PixelRect(enclosing: CGRect(x: 0.5, y: 1.2, width: 2, height: 2)), PixelRect(x: 0, y: 1, width: 3, height: 3))
  }
}
