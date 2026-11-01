import CoreGraphics
import CryptoKit
import Foundation

public struct MermaidRequest: Sendable {
  public static let widthBucketSize: CGFloat = 8
  public static let scaleRange: ClosedRange<CGFloat> = 0.25...8

  public var code: String
  public var theme: MermaidTheme
  public var width: CGFloat
  public var scale: CGFloat

  public init(code: String, theme: MermaidTheme, width: CGFloat, scale: CGFloat) {
    self.code = code
    self.theme = theme
    self.width = width
    self.scale = scale
  }

  public var widthBucket: Int {
    guard width.isFinite else { return 1 }
    return max(1, Int((width / Self.widthBucketSize).rounded(.down)))
  }

  public var effectiveWidth: CGFloat { CGFloat(widthBucket) * Self.widthBucketSize }

  public var effectiveScale: CGFloat {
    scale.isFinite ? min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound) : 1
  }

  public var key: MermaidCacheKey {
    MermaidCacheKey(
      sourceDigest: SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined(),
      themeDigest: theme.digest, widthBucket: widthBucket, scale: Int((effectiveScale * 100).rounded()))
  }
}

public struct MermaidCacheKey: Hashable, Sendable {
  public var sourceDigest: String
  public var themeDigest: String
  public var widthBucket: Int
  public var scale: Int
}

public enum MermaidFailure: Equatable, Sendable {
  case syntax(String)
  case timedOut
  case unavailable(String)

  var message: String {
    switch self {
    case .syntax(let message): message
    case .timedOut: "Rendering the diagram timed out."
    case .unavailable(let reason): "Mermaid is unavailable: \(reason)"
    }
  }

  var isCacheable: Bool {
    switch self {
    case .syntax, .timedOut: true
    case .unavailable: false
    }
  }
}

public struct MermaidDiagram: @unchecked Sendable {
  public let size: CGSize
  public let image: CGImage
  public let failure: MermaidFailure?

  var byteCost: Int { image.bytesPerRow * image.height }
}

struct MermaidImageCache {
  private struct Entry {
    var diagram: MermaidDiagram
    var lastUse: UInt64
  }

  let byteLimit: Int
  private var entries: [MermaidCacheKey: Entry] = [:]
  private var clock: UInt64 = 0
  private(set) var totalBytes = 0

  init(byteLimit: Int) {
    self.byteLimit = byteLimit
  }

  var count: Int { entries.count }

  mutating func value(for key: MermaidCacheKey) -> MermaidDiagram? {
    guard var entry = entries[key] else { return nil }
    clock += 1
    entry.lastUse = clock
    entries[key] = entry
    return entry.diagram
  }

  mutating func insert(_ diagram: MermaidDiagram, for key: MermaidCacheKey) {
    guard diagram.byteCost <= byteLimit else { return }
    if let previous = entries.removeValue(forKey: key) {
      totalBytes -= previous.diagram.byteCost
    }
    clock += 1
    entries[key] = Entry(diagram: diagram, lastUse: clock)
    totalBytes += diagram.byteCost
    while totalBytes > byteLimit, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
      entries.removeValue(forKey: oldest.key)
      totalBytes -= oldest.value.diagram.byteCost
    }
  }
}
