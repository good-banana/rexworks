import Foundation

public func parseColorReply(_ s: String) -> (r: Double, g: Double, b: Double)? {
  guard let marker = s.range(of: "rgb:") else { return nil }
  let body = s[marker.upperBound...].prefix { $0 != "\u{1b}" && $0 != "\u{07}" }
  let parts = body.split(separator: "/", omittingEmptySubsequences: false)
  guard parts.count == 3 else { return nil }
  var values: [Double] = []
  for part in parts {
    guard (1...4).contains(part.count), let raw = UInt32(part, radix: 16) else { return nil }
    let maximum = Double((1 << (4 * part.count)) - 1)
    values.append(Double(raw) / maximum)
  }
  return (values[0], values[1], values[2])
}

public func isDark(_ rgb: (r: Double, g: Double, b: Double)) -> Bool {
  0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b < 0.5
}

public struct RGB: Hashable, Sendable, CustomStringConvertible {
  public var r: Double
  public var g: Double
  public var b: Double

  public init(_ r: Double, _ g: Double, _ b: Double) {
    self.r = min(max(r, 0), 1)
    self.g = min(max(g, 0), 1)
    self.b = min(max(b, 0), 1)
  }

  public init(hex: UInt32) {
    self.init(
      Double((hex >> 16) & 0xff) / 255, Double((hex >> 8) & 0xff) / 255, Double(hex & 0xff) / 255)
  }

  public init(_ tuple: (r: Double, g: Double, b: Double)) {
    self.init(tuple.r, tuple.g, tuple.b)
  }

  public var tuple: (r: Double, g: Double, b: Double) { (r, g, b) }

  public var description: String {
    "#" + [r, g, b].map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
  }

  public var isDark: Bool { MDViewerCore.isDark(tuple) }

  public var relativeLuminance: Double {
    func linear(_ c: Double) -> Double {
      c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
  }

  public func contrast(with other: RGB) -> Double {
    let a = relativeLuminance
    let b = other.relativeLuminance
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  public func mixed(with other: RGB, _ amount: Double) -> RGB {
    RGB(r + (other.r - r) * amount, g + (other.g - g) * amount, b + (other.b - b) * amount)
  }
}

public enum TerminalColorTarget: Hashable, Sendable {
  case foreground
  case background
  case palette(Int)
}

public func parseOSCColorReply(_ body: String) -> (target: TerminalColorTarget, color: RGB)? {
  let fields = body.split(separator: ";", omittingEmptySubsequences: false)
  let target: TerminalColorTarget
  let value: Substring
  switch fields.first {
  case "10" where fields.count == 2:
    target = .foreground
    value = fields[1]
  case "11" where fields.count == 2:
    target = .background
    value = fields[1]
  case "4" where fields.count == 3:
    guard let index = Int(fields[1]), (0..<256).contains(index) else { return nil }
    target = .palette(index)
    value = fields[2]
  default:
    return nil
  }
  guard value.hasPrefix("rgb:"), let rgb = parseColorReply(String(value)) else { return nil }
  return (target, RGB(rgb))
}

public struct TerminalColorSet: Equatable, Sendable {
  public static let paletteSize = 16

  public var foreground: RGB?
  public var background: RGB?
  public var palette: [RGB?]
  public var colorScheme: ColorScheme?

  public init(
    foreground: RGB? = nil, background: RGB? = nil, palette: [RGB?] = [], colorScheme: ColorScheme? = nil
  ) {
    self.foreground = foreground
    self.background = background
    self.colorScheme = colorScheme
    self.palette = (0..<Self.paletteSize).map { $0 < palette.count ? palette[$0] : nil }
  }

  public mutating func record(_ target: TerminalColorTarget, _ color: RGB) {
    switch target {
    case .foreground: foreground = foreground ?? color
    case .background: background = background ?? color
    case .palette(let index) where index < Self.paletteSize:
      palette[index] = palette[index] ?? color
    case .palette: break
    }
  }
}

public enum TerminalColorQuery {
  public static func request(includePalette: Bool) -> String {
    let dynamic = "\u{1b}]10;?\u{1b}\\\u{1b}]11;?\u{1b}\\"
    let palette =
      includePalette ? (0..<TerminalColorSet.paletteSize).map { "\u{1b}]4;\($0);?\u{1b}\\" }.joined() : ""
    return dynamic + palette + colorSchemeQuery + primaryDeviceAttributes
  }

  public static let colorSchemeQuery = "\u{1b}[?996n"
  public static let primaryDeviceAttributes = "\u{1b}[c"
}

public struct TerminalColorReplyReader {
  private static let maximumPending = 4096

  public private(set) var colors = TerminalColorSet()
  public private(set) var terminalFinishedReplying = false
  private let expectsPalette: Bool
  private var pending: [UInt8] = []

  public init(expectsPalette: Bool) {
    self.expectsPalette = expectsPalette
  }

  public var isComplete: Bool {
    terminalFinishedReplying || allColorsReceived
  }

  private var allColorsReceived: Bool {
    colors.colorScheme != nil && colors.foreground != nil && colors.background != nil
      && (!expectsPalette || !colors.palette.contains(nil))
  }

  public mutating func feed(_ bytes: [UInt8]) {
    pending.append(contentsOf: bytes)
    var index = 0
    var keepFrom = pending.count
    scan: while index < pending.count {
      guard pending[index] == 0x1b else {
        index += 1
        continue
      }
      guard index + 1 < pending.count else {
        keepFrom = index
        break
      }
      if pending[index + 1] == 0x5b {
        guard let final = (index + 2..<pending.count).first(where: { (0x40...0x7e).contains(pending[$0]) })
        else {
          keepFrom = index
          break
        }
        acceptCSI(params: pending[(index + 2)..<final], final: pending[final])
        index = final + 1
        continue
      }
      guard pending[index + 1] == 0x5d else {
        index += 1
        continue
      }
      var cursor = index + 2
      while cursor < pending.count {
        let byte = pending[cursor]
        if byte == 0x07 {
          accept(pending[(index + 2)..<cursor])
          index = cursor + 1
          continue scan
        }
        if byte == 0x1b {
          guard cursor + 1 < pending.count else {
            keepFrom = index
            break scan
          }
          if pending[cursor + 1] == 0x5c {
            accept(pending[(index + 2)..<cursor])
            index = cursor + 2
          } else {
            index = cursor
          }
          continue scan
        }
        cursor += 1
      }
      keepFrom = index
      break
    }
    pending.removeFirst(min(keepFrom, pending.count))
    if pending.count > Self.maximumPending { pending.removeAll() }
  }

  private mutating func acceptCSI(params: ArraySlice<UInt8>, final: UInt8) {
    let text = String(decoding: params, as: UTF8.self)
    if final == 0x63, text.hasPrefix("?") {
      terminalFinishedReplying = true
    } else if let scheme = ColorScheme(reportParams: text, final: final) {
      colors.colorScheme = colors.colorScheme ?? scheme
    }
  }

  private mutating func accept(_ body: ArraySlice<UInt8>) {
    guard let reply = parseOSCColorReply(String(decoding: body, as: UTF8.self)) else { return }
    colors.record(reply.target, reply.color)
  }
}
