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

  var source: MermaidSourceKey { MermaidSourceKey(sourceDigest: sourceDigest, themeDigest: themeDigest) }
}

struct MermaidSourceKey: Hashable, Sendable {
  var sourceDigest: String
  var themeDigest: String
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
    var expiry: Date?
  }

  let byteLimit: Int
  private var entries: [MermaidCacheKey: Entry] = [:]
  private var clock: UInt64 = 0
  private(set) var totalBytes = 0
  var pinned: Set<MermaidCacheKey> = [] {
    didSet { trim() }
  }

  init(byteLimit: Int) {
    self.byteLimit = byteLimit
  }

  var count: Int { entries.count }

  mutating func value(for key: MermaidCacheKey, now: Date = Date()) -> MermaidDiagram? {
    guard var entry = entries[key] else { return nil }
    if let expiry = entry.expiry, expiry <= now {
      remove(key)
      return nil
    }
    clock += 1
    entry.lastUse = clock
    entries[key] = entry
    return entry.diagram
  }

  mutating func insert(_ diagram: MermaidDiagram, for key: MermaidCacheKey, expiry: Date? = nil) {
    remove(key)
    guard diagram.byteCost <= byteLimit || pinned.contains(key) else { return }
    clock += 1
    entries[key] = Entry(diagram: diagram, lastUse: clock, expiry: expiry)
    totalBytes += diagram.byteCost
    trim()
  }

  mutating func remove(_ key: MermaidCacheKey) {
    if let previous = entries.removeValue(forKey: key) {
      totalBytes -= previous.diagram.byteCost
    }
  }

  private mutating func trim() {
    while totalBytes > byteLimit,
      let oldest = entries.filter({ !pinned.contains($0.key) }).min(by: { $0.value.lastUse < $1.value.lastUse })
    {
      remove(oldest.key)
    }
  }
}
