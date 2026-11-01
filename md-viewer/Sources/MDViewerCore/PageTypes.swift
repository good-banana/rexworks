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
