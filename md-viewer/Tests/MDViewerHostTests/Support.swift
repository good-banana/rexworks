import CoreGraphics
import Foundation
import ImageIO
import MDViewerCore
import MDViewerDisplay
import MDViewerInteraction
import XCTest

@testable import MDViewerHost

final class RecordingOutput: TerminalOutput {
  var writes: [String] = []

  func write(_ text: String) { writes.append(text) }

  var joined: String { writes.joined() }

  func take() -> [String] {
    defer { writes = [] }
    return writes
  }
}

final class FakePasteboard: PasteboardWriting {
  var writes: [(text: String, markdown: Bool)] = []
  var succeeds = true

  func write(_ text: String, markdown: Bool) -> Bool {
    guard succeeds else { return false }
    writes.append((text, markdown))
    return true
  }
}

final class MemoryStager: FrameStager {
  let name = "memory"
  private var sequence: UInt64 = 0
  private(set) var staged: [UInt64] = []

  var outstanding: Int { staged.count }

  func stage(_ bytes: UnsafeRawBufferPointer, at now: UInt64) throws -> StagedFrame {
    sequence += 1
    staged.append(sequence)
    return StagedFrame(medium: .sharedMemory("/mdv-test-\(sequence)"), sequence: sequence)
  }

  func acknowledge(through sequence: UInt64) { staged.removeAll { $0 <= sequence } }
  func reclaim(olderThan cutoff: UInt64) {}
  func removeAll() { staged = [] }
}

final class TestDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  @discardableResult
  func write(_ name: String, _ text: String) throws -> URL {
    let file = url.appendingPathComponent(name)
    try Data(text.utf8).write(to: file)
    return file
  }
}

let testPaneSize = PaneSize(columns: 100, rows: 40, pixelWidth: 1600, pixelHeight: 1400)

final class ThemeCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var received: [TerminalColorSet] = []
  var colors: [TerminalColorSet] { lock.withLock { received } }
  func record(_ colors: TerminalColorSet) { lock.withLock { received.append(colors) } }
}

@MainActor
struct HostFixture {
  let host: ViewerHost
  let output: RecordingOutput
  let pasteboard = FakePasteboard()
  let directory: TestDirectory
  let file: URL
  let themeCalls: ThemeCalls

  init(
    _ markdown: String, files: [String: String] = [:], start: Bool = true,
    resolve: (@Sendable (TerminalColorSet) -> ResolvedTheme)? = nil,
    posterFrame: (@Sendable (URL) -> CGImage?)? = nil,
    fetchRemote: (@Sendable (URL, @escaping @Sendable (Data?) -> Void) -> Void)? = nil
  ) throws {
    directory = try TestDirectory()
    file = try directory.write("main.md", markdown)
    for (name, text) in files { try directory.write(name, text) }
    output = RecordingOutput()
    let calls = ThemeCalls()
    themeCalls = calls
    let fallback = ResolvedTheme(colors: RenderPalette.fallbackColors(dark: true), source: .terminalQuery)
    let services = HostServices(
      output: output, pasteboard: pasteboard, stagers: (MemoryStager(), nil),
      environment: InteractionEnvironment(openURL: { _ in true }, copyOnSelect: { false }),
      images: ImageStore(fetchRemote: fetchRemote, posterFrame: posterFrame),
      resolveTheme: { colors in
        calls.record(colors)
        return resolve?(colors) ?? fallback
      },
      watchesFiles: false)
    host = ViewerHost(size: testPaneSize, theme: fallback, services: services)
    if start { host.start(file: file, windowSize: testPaneSize) }
  }

  func acknowledgeFrames() {
    for fence in fences(in: output.joined) {
      host.receive(Array("\u{1b}_Gi=\(fence);OK\u{1b}\\".utf8))
    }
  }
}

func fences(in text: String) -> [UInt32] {
  var result: [UInt32] = []
  var rest = Substring(text)
  while let range = rest.range(of: "a=q,i=") {
    let digits = rest[range.upperBound...].prefix { $0.isNumber }
    if let value = UInt32(digits) { result.append(value) }
    rest = rest[range.upperBound...]
  }
  return result
}

@MainActor
func spin(_ seconds: TimeInterval) {
  RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition(), Date() < deadline { spin(0.01) }
}

func solidImage(width: Int, height: Int) -> CGImage {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.2, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  return context.makeImage()!
}

func pngData(width: Int, height: Int) -> Data {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let image = context.makeImage()!
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  CGImageDestinationFinalize(destination)
  return data as Data
}
