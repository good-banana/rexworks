import AppKit
import Darwin
import MDViewerCore
import MDViewerWeb
import UniformTypeIdentifiers

nonisolated(unsafe) private var tileDirectoryToRemove: String?

private func removeTileDirectory() {
  guard let path = tileDirectoryToRemove else { return }
  tileDirectoryToRemove = nil
  try? FileManager.default.removeItem(atPath: path)
}

struct TileLayout: Equatable {
  var pixelWidth: Int
  var tileHeight: Int
  var scale: CGFloat
  var pageHeight: CGFloat
  var background: String

  var cssWidth: CGFloat { CGFloat(pixelWidth) / scale }
  var cssTileHeight: CGFloat { CGFloat(tileHeight) / scale }
}

enum TileError: Error, LocalizedError {
  case directory(String)
  case encode

  var errorDescription: String? {
    switch self {
    case .directory(let path): return "could not create tile directory \(path)"
    case .encode: return "could not encode tile image"
    }
  }
}

@MainActor
final class TileCache {
  static let keepDistance = 3

  private let renderer: WebRenderer
  private let directory: URL
  private(set) var layout: TileLayout?
  private var generation = 0
  private var images: [Int: UInt32] = [:]
  private var wanted: [Int] = []
  private var failed: Set<Int> = []
  private var busy = false
  private var nextImageID: UInt32 = 1
  private var nextFileNumber = 0
  var onTileReady: () -> Void = {}
  var onError: (Error) -> Void = { _ in }

  init(renderer: WebRenderer) throws {
    self.renderer = renderer
    directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tty-graphics-protocol-md-viewer-\(getpid())", isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    guard mkdir(directory.path, 0o700) == 0 else { throw TileError.directory(directory.path) }
    tileDirectoryToRemove = directory.path
    atexit { removeTileDirectory() }
  }

  func image(for index: Int) -> UInt32? {
    images[index]
  }

  func invalidate() {
    generation += 1
    wanted = []
  }

  func reset(layout: TileLayout) {
    invalidate()
    Terminal.write(images.values.map(Kitty.deleteImage).joined())
    images = [:]
    failed = []
    self.layout = layout
  }

  func want(_ indices: [Int], tileCount: Int) {
    var seen = Set<Int>()
    wanted = indices.filter { (0..<tileCount).contains($0) && seen.insert($0).inserted }
    pump()
  }

  func evict(farFrom indices: ClosedRange<Int>) {
    let stale = images.keys.filter {
      $0 < indices.lowerBound - Self.keepDistance || $0 > indices.upperBound + Self.keepDistance
    }
    var output = ""
    for index in stale {
      guard let id = images.removeValue(forKey: index) else { continue }
      output += Kitty.deletePlacements(id: id) + Kitty.deleteImage(id: id)
    }
    if !output.isEmpty { Terminal.write(output) }
  }

  func removeDirectory() {
    removeTileDirectory()
  }

  private func pump() {
    guard !busy, let layout, let index = wanted.first(where: { images[$0] == nil && !failed.contains($0) }) else {
      return
    }
    busy = true
    let generation = generation
    Task { @MainActor in
      do {
        let image = try await snapshot(index: index, layout: layout)
        if generation == self.generation {
          images[index] = try transmit(image)
          onTileReady()
        }
      } catch {
        if generation == self.generation {
          failed.insert(index)
          onError(error)
        }
      }
      busy = false
      pump()
    }
  }

  private func snapshot(index: Int, layout: TileLayout) async throws -> CGImage {
    let top = CGFloat(index) * layout.cssTileHeight
    let height = max(1, min(layout.cssTileHeight, layout.pageHeight - top))
    let snapshot = try await renderer.snapshot(
      rect: CGRect(x: 0, y: top, width: layout.cssWidth, height: height))
    guard let source = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: layout.pixelWidth, height: layout.tileHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw TileError.encode }
    let canvas = CGRect(x: 0, y: 0, width: layout.pixelWidth, height: layout.tileHeight)
    context.setFillColor(Self.color(hex: layout.background))
    context.fill(canvas)
    context.interpolationQuality = .high
    let drawnHeight = (height * layout.scale).rounded()
    context.draw(
      source, in: CGRect(x: 0, y: canvas.height - drawnHeight, width: canvas.width, height: drawnHeight))
    guard let tile = context.makeImage() else { throw TileError.encode }
    return tile
  }

  private func transmit(_ image: CGImage) throws -> UInt32 {
    nextFileNumber += 1
    let url = directory.appendingPathComponent("\(nextFileNumber).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw TileError.encode }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw TileError.encode }
    let id = nextImageID
    nextImageID = nextImageID == UInt32.max ? 1 : nextImageID + 1
    Terminal.write(Kitty.transmitFile(id: id, path: url.path))
    return id
  }

  private static func color(hex: String) -> CGColor {
    let value = Int(hex.dropFirst(), radix: 16) ?? 0
    return CGColor(
      srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
      blue: CGFloat(value & 0xff) / 255, alpha: 1)
  }
}
