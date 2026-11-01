import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PixelColor: Hashable, Sendable, CustomStringConvertible {
  public var r: UInt8
  public var g: UInt8
  public var b: UInt8
  public var a: UInt8

  public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
    self.r = r
    self.g = g
    self.b = b
    self.a = a
  }

  public var description: String { String(format: "#%02x%02x%02x/%02x", r, g, b, a) }

  public func distance(to other: PixelColor) -> Int {
    max(abs(Int(r) - Int(other.r)), abs(Int(g) - Int(other.g)), abs(Int(b) - Int(other.b)))
  }
}

public final class RasterBitmap: @unchecked Sendable {
  public let width: Int
  public let height: Int
  public let context: CGContext

  public init?(width: Int, height: Int) {
    guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    self.width = width
    self.height = height
    self.context = context
  }

  public var bytesPerRow: Int { context.bytesPerRow }

  public var bytes: UnsafeRawBufferPointer {
    UnsafeRawBufferPointer(start: context.data, count: bytesPerRow * height)
  }

  public func pixel(x: Int, y: Int) -> PixelColor? {
    guard x >= 0, y >= 0, x < width, y < height, let data = context.data else { return nil }
    let pointer = data.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
    return PixelColor(r: pointer[0], g: pointer[1], b: pointer[2], a: pointer[3])
  }

  public func makeImage() -> CGImage? { context.makeImage() }

  public func pngData() -> Data? {
    guard let image = makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }
}
