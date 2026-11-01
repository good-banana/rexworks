import CoreGraphics
import Foundation
import XCTest

@testable import MDViewerLayout

final class PerformanceTests: XCTestCase {
  private func milliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
  }

  private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

  func testSampleLayoutPerWidthIsFast() throws {
    let markdown = try fixture("sample")
    var prepared: PreparedDocument?
    let prepareTime = milliseconds { prepared = prepare(markdown) }
    let document = try XCTUnwrap(prepared)
    var times: [Double] = []
    for width in stride(from: 600, through: 2400, by: 12) {
      times.append(milliseconds { _ = document.layout(width: CGFloat(width)) })
    }
    let result = median(times)
    print(
      String(
        format: "sample.md: prepare %.2f ms, layout median %.3f ms over %d widths", prepareTime, result, times.count))
    XCTAssertLessThan(result, 20)
  }

  func testLargeDocumentLayout() throws {
    let markdown = generatedLargeDocument(lines: 5000)
    XCTAssertGreaterThanOrEqual(markdown.split(separator: "\n", omittingEmptySubsequences: false).count, 5000)
    var prepared: PreparedDocument?
    let prepareTime = milliseconds { prepared = prepare(markdown) }
    let document = try XCTUnwrap(prepared)
    var times: [Double] = []
    for width in [700, 1100, 1600, 2400, 1100] {
      times.append(milliseconds { _ = document.layout(width: CGFloat(width)) })
    }
    let page = document.layout(width: 1400)
    var hitTime = 0.0
    var findTime = 0.0
    hitTime = milliseconds {
      for y in stride(from: 0, to: page.height, by: page.height / 200) {
        _ = page.textPosition(at: CGPoint(x: 400, y: y))
      }
    }
    var matches = 0
    findTime = milliseconds { matches = page.find("section").count }
    print(
      String(
        format: "5000-line fixture: prepare %.1f ms, layout median %.2f ms, 200 hit tests %.2f ms, find %d in %.2f ms",
        prepareTime, median(times), hitTime, matches, findTime))
    XCTAssertGreaterThan(matches, 100)
    XCTAssertLessThan(median(times), 400)
  }
}
