import MDViewerCore
import XCTest

@testable import MDViewerDisplay

final class PaneSizeTrackerTests: XCTestCase {
  let padded = PaneSize(columns: 107, rows: 29, pixelWidth: 1510, pixelHeight: 970)

  func testInBandReportsAreTheOnlyPixelSourceOnceSupported() {
    var tracker = PaneSizeTracker()
    XCTAssertEqual(tracker.modeReport(ModeReport(mode: 2048, state: 2)), [])
    XCTAssertEqual(tracker.inBandReports, true)
    XCTAssertEqual(tracker.windowChanged(padded), [])
    let report = PaneSize(columns: 107, rows: 29, pixelWidth: 1498, pixelHeight: 957)
    XCTAssertEqual(tracker.inBandReport(report), [.observe(report)])
    XCTAssertEqual(tracker.cellSizeReport(width: 14, height: 33), [])
  }

  func testAReportImpliesSupportEvenWithoutDECRPM() {
    var tracker = PaneSizeTracker()
    let report = PaneSize(columns: 80, rows: 24, pixelWidth: 640, pixelHeight: 384)
    XCTAssertEqual(tracker.inBandReport(report), [.observe(report)])
    XCTAssertEqual(tracker.windowChanged(padded), [])
  }

  func testWithoutInBandReportsPixelsComeFromTheCellSize() {
    var tracker = PaneSizeTracker()
    XCTAssertEqual(tracker.windowChanged(padded), [.queryCellSize, .observe(padded)])
    XCTAssertEqual(
      tracker.cellSizeReport(width: 14, height: 33),
      [.observe(PaneSize(columns: 107, rows: 29, pixelWidth: 1498, pixelHeight: 957))])
    XCTAssertEqual(
      tracker.windowChanged(PaneSize(columns: 50, rows: 10, pixelWidth: 712, pixelHeight: 343)),
      [.observe(PaneSize(columns: 50, rows: 10, pixelWidth: 700, pixelHeight: 330))])
  }

  func testUnsupportedModeReportUsesTheLastWindowSize() {
    var tracker = PaneSizeTracker()
    _ = tracker.windowChanged(padded)
    XCTAssertEqual(tracker.modeReport(ModeReport(mode: 2048, state: 0)), [.observe(padded)])
    XCTAssertEqual(tracker.inBandReports, false)
    XCTAssertEqual(tracker.modeReport(ModeReport(mode: 2031, state: 2)), [])
    var permanent = PaneSizeTracker()
    _ = permanent.modeReport(ModeReport(mode: 2048, state: 4))
    XCTAssertEqual(permanent.inBandReports, false)
  }

  func testInvalidCellSizeIsIgnored() {
    var tracker = PaneSizeTracker()
    _ = tracker.windowChanged(padded)
    XCTAssertEqual(tracker.cellSizeReport(width: 0, height: 33), [])
    XCTAssertNil(tracker.cellSize)
  }
}
