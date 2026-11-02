import CoreGraphics
import Darwin
import Foundation
import MDViewerCore
import MDViewerLayout
import MDViewerRender
import XCTest

@testable import MDViewerDisplay

final class DisplayBenchmarkTests: XCTestCase {
  private final class Timing {
    var total: [Double] = []
    var render: [Double] = []
    var stage: [Double] = []
    var write: [Double] = []

    func median(_ values: [Double]) -> Double { values.isEmpty ? .nan : values.sorted()[values.count / 2] }
    func p95(_ values: [Double]) -> Double {
      values.isEmpty ? .nan : values.sorted()[min(values.count * 95 / 100, values.count - 1)]
    }

    var summary: String {
      String(
        format: "total median %.2f p95 %.2f ms (render %.2f, stage %.2f, write %.3f)", median(total), p95(total),
        median(render), median(stage), median(write)) + " frames \(render.count)"
    }
  }

  private static func milliseconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1e6 }

  private func makeTransport(
    width: Int, height: Int, stager: FrameStager, prepared: PreparedDocument, timing: Timing
  ) -> (DisplayTransport, RasterFrameSource) {
    let size = PaneSize(columns: width / 16, rows: height / 40, pixelWidth: width, pixelHeight: height)
    let page = prepared.layout(width: CGFloat(width))
    let source = RasterFrameSource(
      rasterizer: Rasterizer(layout: page, palette: .fallback(dark: true)),
      status: StatusBarContent(fileName: "sample.md", folder: "docs", progress: ScrollProgress(start: 0, fraction: 1)))
    let transport = DisplayTransport(
      viewport: DisplayViewport(size: size, statusRows: 1, pageHeight: page.height), output: NullOutput(),
      source: source, stager: stager, firstImageID: 1, settleNanoseconds: 0
    ) { size, old in
      let page = prepared.layout(width: CGFloat(size.columns * (size.pixelWidth / size.columns)))
      source.rasterizer = Rasterizer(layout: page, palette: .fallback(dark: true))
      return DisplayViewport(size: size, statusRows: old.statusRows, pageHeight: page.height, offset: old.offset)
    }
    record(transport, into: timing)
    return (transport, source)
  }

  private func record(_ transport: DisplayTransport, into timing: Timing) {
    transport.onEvent = { event in
      guard case .sent(let record) = event else { return }
      timing.render.append(Self.milliseconds(record.renderNanoseconds))
      timing.stage.append(Self.milliseconds(record.stageNanoseconds))
      timing.write.append(Self.milliseconds(record.writeNanoseconds))
    }
  }

  private var now: UInt64 = 1_000 * ms

  private func run(_ transport: DisplayTransport, rounds: Int, timing: Timing, change: (Int) -> Void) {
    for round in 0..<rounds {
      change(round)
      now += 20 * ms
      let started = DispatchTime.now().uptimeNanoseconds
      transport.pump(at: now)
      timing.total.append(Self.milliseconds(DispatchTime.now().uptimeNanoseconds - started))
      if let fence = transport.pacer.inFlight?.fence {
        transport.handle(GraphicsResponse(id: fence, message: "OK"), at: now + 1)
      }
    }
  }

  private func stagers() throws -> [() throws -> FrameStager] {
    [{ try TemporaryFileStager() }, { SharedMemoryStager(prefix: "/mdvb\(getpid())-") }]
  }

  func testTransportTimings() throws {
    let prepared = PreparedDocument(markdown: try fixture("sample"), typography: Typography(backingScale: 2))
    var lines: [String] = []
    for makeStager in try stagers() {
      for (width, height) in [(1600, 1400), (2560, 1600)] {
        let stager = try makeStager()
        let full = Timing()
        let (transport, _) = makeTransport(
          width: width, height: height, stager: stager, prepared: prepared, timing: full)
        transport.shiftScrolling = false
        run(transport, rounds: 30, timing: full) { round in
          if round > 0 { transport.scroll(by: round % 2 == 0 ? 120 : -80) }
        }
        lines.append("full \(width)x\(height) \(stager.name): \(full.summary)")

        let shifted = Timing()
        record(transport, into: shifted)
        transport.shiftScrolling = true
        run(transport, rounds: 30, timing: shifted) { round in transport.scroll(rows: round % 2 == 0 ? 3 : -2) }
        lines.append("scroll shift + strip \(width)x\(height) \(stager.name): \(shifted.summary)")

        let status = Timing()
        record(transport, into: status)
        run(transport, rounds: 30, timing: status) { _ in transport.invalidateStatusBar() }
        lines.append(
          "patch status bar \(width)x\(transport.viewport.statusBarHeight) \(stager.name): \(status.summary)")

        let strip = Timing()
        record(transport, into: strip)
        run(transport, rounds: 30, timing: strip) { round in
          transport.invalidate(pane: PixelRect(x: 0, y: 200 + (round % 5) * 40, width: width, height: 120))
        }
        lines.append("patch strip \(width)x120 \(stager.name): \(strip.summary)")

        let resize = Timing()
        record(transport, into: resize)
        let base = transport.viewport.size
        run(transport, rounds: 20, timing: resize) { round in
          let columns = base.columns - (round % 2 == 0 ? 10 : 0)
          transport.observe(
            PaneSize(columns: columns, rows: base.rows, pixelWidth: columns * 16, pixelHeight: base.pixelHeight),
            at: now)
        }
        lines.append("resize \(width)x\(height) \(stager.name) (layout + raster + stage + write): \(resize.summary)")
        transport.shutdown()
        XCTAssertLessThan(full.median(full.total), 100)
        XCTAssertLessThan(status.median(status.total), 30)
      }
    }
    print(lines.joined(separator: "\n"))
  }
}

private final class NullOutput: TerminalOutput {
  private let descriptor = open("/dev/null", O_WRONLY)

  deinit { close(descriptor) }

  func write(_ text: String) {
    var bytes = Array(text.utf8)
    _ = Darwin.write(descriptor, &bytes, bytes.count)
  }
}
