import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerDisplay
import MDViewerRender
import XCTest

final class RecordingOutput: TerminalOutput {
  var writes: [String] = []

  func write(_ text: String) { writes.append(text) }

  func take() -> [String] {
    defer { writes = [] }
    return writes
  }
}

final class SolidSource: FrameSource {
  var frames: [DisplayViewport] = []
  var patches: [PixelRect] = []

  func drawFrame(_ viewport: DisplayViewport, into bitmap: RasterBitmap) {
    frames.append(viewport)
    bitmap.context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    bitmap.context.fill(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
  }

  func drawPatch(_ rect: PixelRect, viewport: DisplayViewport, into bitmap: RasterBitmap) {
    patches.append(rect)
  }
}

final class MemoryStager: FrameStager {
  var name: String
  var failNext = false
  var failOnCall: Int?
  private var calls = 0
  var staged: [(sequence: UInt64, bytes: Int, created: UInt64)] = []
  var acknowledged: UInt64 = 0
  var removed = false
  private var sequence: UInt64 = 0

  init(name: String = "memory") {
    self.name = name
  }

  var outstanding: Int { staged.count }

  func stage(_ bytes: UnsafeRawBufferPointer, at now: UInt64) throws -> StagedFrame {
    calls += 1
    if failNext || failOnCall == calls {
      failNext = false
      throw StagingError.create(name, ENOSPC)
    }
    sequence += 1
    staged.append((sequence, bytes.count, now))
    return StagedFrame(medium: .sharedMemory("/\(name)-\(sequence)"), sequence: sequence)
  }

  func acknowledge(through sequence: UInt64) {
    acknowledged = max(acknowledged, sequence)
    staged.removeAll { $0.sequence <= sequence }
  }

  func reclaim(olderThan cutoff: UInt64) {
    staged.removeAll { $0.created < cutoff }
  }

  func removeAll() {
    staged = []
    removed = true
  }
}

let ms: UInt64 = 1_000_000

func paneSize(columns: Int = 100, rows: Int = 40, cellWidth: Int = 16, cellHeight: Int = 35) -> PaneSize {
  PaneSize(columns: columns, rows: rows, pixelWidth: columns * cellWidth, pixelHeight: rows * cellHeight)
}

func fixture(_ name: String) throws -> String {
  let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8)
}

func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
