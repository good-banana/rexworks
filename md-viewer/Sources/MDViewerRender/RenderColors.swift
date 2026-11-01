import CoreGraphics
import MDViewerCore
import MDViewerDocument
import MDViewerLayout

extension RGB {
  public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

  public var pixel: PixelColor {
    func byte(_ value: Double) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
    return PixelColor(r: byte(r), g: byte(g), b: byte(b))
  }

  func cgColor(alpha: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
}

extension RenderPalette {
  public func color(for role: TextColorRole) -> RGB {
    switch role {
    case .text: text
    case .muted: mutedText
    case .heading: headingText
    case .link: link
    case .inlineCode: inlineCodeText
    case .code: text
    case .alertTitle(let kind): alert(kind)
    }
  }

  public func alert(_ kind: AlertKind) -> RGB {
    switch kind {
    case .note: alerts.note
    case .tip: alerts.tip
    case .important: alerts.important
    case .warning: alerts.warning
    case .caution: alerts.caution
    }
  }

  public func color(for token: SyntaxToken) -> RGB {
    switch token {
    case .keyword: syntax.keyword
    case .string: syntax.string
    case .number: syntax.number
    case .comment: syntax.comment
    case .function: syntax.function
    case .type: syntax.type
    case .variable: syntax.variable
    case .operatorSymbol: syntax.operatorSymbol
    case .punctuation: syntax.punctuation
    case .metaTag: syntax.metaTag
    case .attribute: syntax.attribute
    }
  }
}

struct ColorTable {
  let palette: RenderPalette

  init(_ palette: RenderPalette) { self.palette = palette }

  func callAsFunction(_ value: RGB) -> CGColor { value.cgColor }

  func callAsFunction(_ keyPath: KeyPath<RenderPalette, RGB>) -> CGColor { self(palette[keyPath: keyPath]) }

  func callAsFunction(_ role: TextColorRole) -> CGColor { self(palette.color(for: role)) }

  func callAsFunction(_ token: SyntaxToken) -> CGColor { self(palette.color(for: token)) }

  func faded(_ keyPath: KeyPath<RenderPalette, RGB>, _ alpha: Double) -> CGColor {
    palette[keyPath: keyPath].cgColor(alpha: alpha)
  }
}
