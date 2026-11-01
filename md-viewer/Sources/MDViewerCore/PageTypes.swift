import CoreGraphics

public struct Theme: Equatable, Sendable {
  public var dark: Bool
  public var background: String
  public var foreground: String

  public init(dark: Bool, background: String, foreground: String) {
    self.dark = dark
    self.background = background
    self.foreground = foreground
  }

  public init(foreground: (r: Double, g: Double, b: Double)?, background: (r: Double, g: Double, b: Double)?) {
    let dark = background.map(isDark) ?? true
    self.dark = dark
    self.background = background.map(Self.hex) ?? (dark ? "#1e1e1e" : "#ffffff")
    self.foreground = foreground.map(Self.hex) ?? (dark ? "#d4d4d4" : "#1f2328")
  }

  private static func hex(_ rgb: (r: Double, g: Double, b: Double)) -> String {
    let channels = [rgb.r, rgb.g, rgb.b].map { Int((min(max($0, 0), 1) * 255).rounded()) }
    return "#" + channels.map { String(format: "%02x", $0) }.joined()
  }
}

public struct PageLink: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case link
    case video
  }

  public var href: String
  public var kind: Kind
  public var rect: CGRect

  public init(href: String, kind: Kind, rect: CGRect) {
    self.href = href
    self.kind = kind
    self.rect = rect
  }
}
