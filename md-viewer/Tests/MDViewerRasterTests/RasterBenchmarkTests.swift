import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout
import XCTest

@testable import MDViewerRender

final class RasterBenchmarkTests: XCTestCase {
  private func milliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
  }

  private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(Int(Double(sorted.count) * fraction), sorted.count - 1)]
  }

  func testRasterAndHighlightTimings() throws {
    let prepared = prepare(try fixture("sample") + "\n" + (try fixture("elements")))
    let highlighter = SyntaxHighlighter()
    let blocks = prepared.codeBlocks.filter { !$0.value.isDiagram }
    var highlightTimes: [Double] = []
    var highlights: [BlockID: HighlightResult] = [:]
    let coldTime = milliseconds { highlights = highlightAll(prepared, highlighter: highlighter) }
    let warm = SyntaxHighlighter(configuration: uncached)
    _ = highlightAll(prepare("```swift\nlet warmUp = 1\n```\n"), highlighter: warm)
    for (_, block) in blocks {
      let done = DispatchSemaphore(value: 0)
      highlightTimes.append(
        milliseconds {
          warm.highlight(code: block.code, language: block.language, queue: DispatchQueue.global()) { _ in
            done.signal()
          }
          done.wait()
        })
    }
    let page = prepared.layout(width: 1600)
    let rasterizer = Rasterizer(layout: page, palette: RenderPalette.fallback(dark: true), highlights: highlights)
    let viewport = try XCTUnwrap(RasterBitmap(width: 1600, height: 1400))
    let strip = try XCTUnwrap(RasterBitmap(width: 1600, height: 120))
    let overlay = RenderOverlay(selection: 40..<400, findMatches: page.find("index"), currentMatch: 0)
    var full: [Double] = []
    var strips: [Double] = []
    for round in 0..<60 {
      let y = CGFloat(round % 6) * 300
      full.append(
        milliseconds {
          rasterizer.draw(CGRect(x: 0, y: y, width: 1600, height: 1400), into: viewport, overlay: overlay)
        })
      strips.append(
        milliseconds {
          rasterizer.draw(CGRect(x: 0, y: y + 500, width: 1600, height: 120), into: strip, overlay: overlay)
        })
    }
    print(
      String(
        format:
          "raster 1600x1400: median %.2f ms p95 %.2f ms; strip 1600x120: median %.3f ms p95 %.3f ms; highlight cold %.1f ms (%d blocks), warm per block median %.2f ms",
        percentile(full, 0.5), percentile(full, 0.95), percentile(strips, 0.5), percentile(strips, 0.95), coldTime,
        blocks.count, percentile(highlightTimes, 0.5)))
    XCTAssertLessThan(percentile(full, 0.5), 100)
    XCTAssertLessThan(percentile(strips, 0.5), 30)
  }
}

private let uncached: SyntaxHighlighter.Configuration = {
  var configuration = SyntaxHighlighter.Configuration()
  configuration.cacheLimit = 1
  return configuration
}()
