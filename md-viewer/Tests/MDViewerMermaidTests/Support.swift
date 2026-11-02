import CoreGraphics
import Foundation
import MDViewerCore
import XCTest

@testable import MDViewerMermaid

func sampleFlowchart() throws -> String {
  let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "md", subdirectory: "Fixtures"))
  let markdown = try String(contentsOf: url, encoding: .utf8)
  let start = try XCTUnwrap(markdown.range(of: "```mermaid\n"))
  let end = try XCTUnwrap(markdown.range(of: "\n```", range: start.upperBound..<markdown.endIndex))
  return String(markdown[start.upperBound..<end.lowerBound])
}

final class RenderRecording: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []
  private var sizes: [CGSize] = []

  func size(_ size: CGSize) {
    lock.withLock {
      events.append("size")
      sizes.append(size)
    }
  }

  func completed() {
    lock.withLock { events.append("image") }
  }

  var recordedEvents: [String] { lock.withLock { events } }
  var recordedSizes: [CGSize] { lock.withLock { sizes } }
}

func render(
  _ renderer: MermaidRenderer, _ request: MermaidRequest, queue: DispatchQueue = .main,
  recording: RenderRecording = RenderRecording()
) async -> MermaidDiagram {
  await withCheckedContinuation { continuation in
    renderer.render(
      request, queue: queue, sizeReady: { recording.size($0) },
      completion: { diagram in
        recording.completed()
        continuation.resume(returning: diagram)
      })
  }
}

struct PixelBuffer {
  let width: Int
  let height: Int
  private let bytes: [UInt8]

  init(_ image: CGImage) {
    width = image.width
    height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
      let context = CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    self.bytes = bytes
  }

  func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let offset = (y * width + x) * 4
    return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
  }

  func distance(_ x: Int, _ y: Int, to color: RGB) -> Int {
    let pixel = pixel(x, y)
    let target = (Int((color.r * 255).rounded()), Int((color.g * 255).rounded()), Int((color.b * 255).rounded()))
    return max(abs(pixel.r - target.0), abs(pixel.g - target.1), abs(pixel.b - target.2))
  }

  func count(near color: RGB, tolerance: Int = 4) -> Int {
    var total = 0
    for y in 0..<height {
      for x in 0..<width where distance(x, y, to: color) <= tolerance {
        total += 1
      }
    }
    return total
  }
}

@MainActor
func waitUntil(
  timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() {
    guard Date() < deadline else { return XCTFail("condition not met in \(timeout) s", file: file, line: line) }
    try await Task.sleep(nanoseconds: 20_000_000)
  }
}

func pause(_ seconds: TimeInterval) async throws {
  try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

final class DiagramResults: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Int: MermaidDiagram] = [:]

  func set(_ index: Int, _ diagram: MermaidDiagram) {
    lock.withLock { results[index] = diagram }
  }

  func get(_ index: Int) -> MermaidDiagram? {
    lock.withLock { results[index] }
  }
}
