import Foundation

public struct RenderPalette: Equatable, Sendable {
  public struct Alerts: Equatable, Sendable {
    public var note: RGB
    public var tip: RGB
    public var important: RGB
    public var warning: RGB
    public var caution: RGB
  }

  public struct Syntax: Equatable, Sendable {
    public var keyword: RGB
    public var string: RGB
    public var number: RGB
    public var comment: RGB
    public var function: RGB
    public var type: RGB
    public var variable: RGB
    public var operatorSymbol: RGB
    public var punctuation: RGB
    public var metaTag: RGB
    public var attribute: RGB
  }

  public struct ContrastRequirement: Sendable {
    public var name: String
    public var token: WritableKeyPath<RenderPalette, RGB> & Sendable
    public var backdrop: KeyPath<RenderPalette, RGB> & Sendable
    public var minimum: Double
  }

  public static let textContrast = 4.5
  public static let uiContrast = 3.0

  public var dark: Bool
  public var pageBackground: RGB
  public var text: RGB
  public var mutedText: RGB
  public var headingText: RGB
  public var link: RGB
  public var linkVisited: RGB
  public var inlineCodeBackground: RGB
  public var inlineCodeText: RGB
  public var codeBlockBackground: RGB
  public var border: RGB
  public var tableHeaderFill: RGB
  public var tableStripe: RGB
  public var blockquoteBar: RGB
  public var alerts: Alerts
  public var selectionFill: RGB
  public var findHighlight: RGB
  public var markHighlight: RGB
  public var currentMatchHighlight: RGB
  public var focusOutline: RGB
  public var statusBarBackground: RGB
  public var statusBarText: RGB
  public var statusMutedText: RGB
  public var statusHintText: RGB
  public var progressTrack: RGB
  public var progressFill: RGB
  public var frontmatterBackground: RGB
  public var frontmatterBar: RGB
  public var syntax: Syntax

  public init(colors: TerminalColorSet) {
    let dark =
      colors.background?.isDark ?? colors.colorScheme.map { $0 == .dark } ?? colors.foreground.map { !$0.isDark }
      ?? true
    let fallback = Self.fallbackColors(dark: dark)
    let bg = colors.background ?? fallback.background ?? RGB(white: 0)
    let fg = colors.foreground ?? fallback.foreground ?? RGB(white: 1)
    let ansi = (0..<TerminalColorSet.paletteSize).map { colors.palette[$0] ?? fallback.palette[$0] ?? fg }

    func hue(_ index: Int) -> RGB {
      let normal = ansi[index]
      let bright = ansi[index + 8]
      let sameHue = Self.hueDistance(normal.hsl.hue, bright.hsl.hue) <= 30
      let similarSaturation = bright.hsl.saturation >= normal.hsl.saturation * 0.7
      let brighter = bright.contrast(with: bg) > normal.contrast(with: bg)
      return sameHue && similarSaturation && brighter ? bright : normal
    }
    let red = hue(1)
    let green = hue(2)
    let yellow = hue(3)
    let blue = hue(4)
    let magenta = hue(5)
    let cyan = hue(6)
    let tint = { (amount: Double) in bg.mixed(with: fg, amount) }

    self.dark = dark
    pageBackground = bg
    text = fg
    mutedText = fg.mixed(with: bg, 0.35)
    headingText = fg
    link = blue
    linkVisited = blue
    inlineCodeBackground = tint(0.1)
    inlineCodeText = fg
    codeBlockBackground = tint(0.06)
    border = tint(0.2)
    tableHeaderFill = tint(0.08)
    tableStripe = tint(0.035)
    blockquoteBar = tint(0.3)
    alerts = Alerts(note: blue, tip: green, important: magenta, warning: yellow, caution: red)
    selectionFill = colors.selectionBackground ?? bg.mixed(with: blue, 0.35)
    findHighlight = bg.mixed(with: yellow, 0.3)
    markHighlight = bg.mixed(with: yellow.mixed(with: green, 0.35), 0.45)
    currentMatchHighlight = bg.mixed(with: yellow.mixed(with: red, 0.5), 0.55)
    focusOutline = blue
    statusBarBackground = tint(0.07)
    statusBarText = fg.mixed(with: bg, 0.2)
    statusMutedText = fg.mixed(with: bg, 0.38)
    statusHintText = fg.mixed(with: bg, 0.48)
    progressTrack = tint(0.18)
    progressFill = blue
    frontmatterBackground = tint(0.04)
    frontmatterBar = tint(0.3)
    syntax = Syntax(
      keyword: magenta, string: green, number: cyan, comment: ansi[8], function: blue, type: yellow,
      variable: red, operatorSymbol: fg, punctuation: fg.mixed(with: bg, 0.25), metaTag: red,
      attribute: yellow)

    for requirement in Self.contrastRequirements {
      self[keyPath: requirement.token] = ensureContrast(
        self[keyPath: requirement.token], against: self[keyPath: requirement.backdrop],
        minimum: requirement.minimum)
    }
  }

  static func hueDistance(_ a: Double, _ b: Double) -> Double {
    let distance = abs(a - b).truncatingRemainder(dividingBy: 360)
    return min(distance, 360 - distance)
  }

  public static func fallback(dark: Bool) -> RenderPalette {
    RenderPalette(colors: fallbackColors(dark: dark))
  }

  public static func fallbackColors(dark: Bool) -> TerminalColorSet {
    if dark {
      return TerminalColorSet(
        foreground: RGB(hex: 0xd4d4d4), background: RGB(hex: 0x1e1e1e),
        palette: [
          0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
          0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
        ].map { RGB(hex: $0) })
    }
    return TerminalColorSet(
      foreground: RGB(hex: 0x1f2328), background: RGB(hex: 0xffffff),
      palette: [
        0x24292f, 0xcf222e, 0x116329, 0x4d2d00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
        0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f,
      ].map { RGB(hex: $0) })
  }

  public static var contrastRequirements: [ContrastRequirement] {
    typealias Token = WritableKeyPath<RenderPalette, RGB> & Sendable
    func on(_ backdrop: KeyPath<RenderPalette, RGB> & Sendable, _ minimum: Double, _ tokens: [(String, Token)])
      -> [ContrastRequirement]
    {
      tokens.map { ContrastRequirement(name: $0.0, token: $0.1, backdrop: backdrop, minimum: minimum) }
    }
    return on(
      \.pageBackground, textContrast,
      [
        ("text", \.text), ("mutedText", \.mutedText), ("headingText", \.headingText), ("link", \.link),
        ("linkVisited", \.linkVisited), ("alerts.note", \.alerts.note), ("alerts.tip", \.alerts.tip),
        ("alerts.important", \.alerts.important), ("alerts.warning", \.alerts.warning),
        ("alerts.caution", \.alerts.caution),
      ])
      + on(\.pageBackground, uiContrast, [("blockquoteBar", \.blockquoteBar), ("focusOutline", \.focusOutline)])
      + on(
        \.text, textContrast,
        [
          ("inlineCodeBackground", \.inlineCodeBackground), ("codeBlockBackground", \.codeBlockBackground),
          ("tableHeaderFill", \.tableHeaderFill), ("tableStripe", \.tableStripe),
          ("selectionFill", \.selectionFill), ("findHighlight", \.findHighlight), ("markHighlight", \.markHighlight),
          ("currentMatchHighlight", \.currentMatchHighlight), ("frontmatterBackground", \.frontmatterBackground),
        ])
      + on(\.inlineCodeBackground, textContrast, [("inlineCodeText", \.inlineCodeText)])
      + on(
        \.statusBarBackground, textContrast,
        [
          ("statusBarText", \.statusBarText), ("statusMutedText", \.statusMutedText),
          ("statusHintText", \.statusHintText),
        ])
      + on(\.statusBarBackground, uiContrast, [("progressFill", \.progressFill)])
      + on(\.frontmatterBackground, uiContrast, [("frontmatterBar", \.frontmatterBar)])
      + on(
        \.codeBlockBackground, textContrast,
        [
          ("syntax.keyword", \.syntax.keyword), ("syntax.string", \.syntax.string),
          ("syntax.number", \.syntax.number), ("syntax.comment", \.syntax.comment),
          ("syntax.function", \.syntax.function), ("syntax.type", \.syntax.type),
          ("syntax.variable", \.syntax.variable), ("syntax.operatorSymbol", \.syntax.operatorSymbol),
          ("syntax.punctuation", \.syntax.punctuation), ("syntax.metaTag", \.syntax.metaTag),
          ("syntax.attribute", \.syntax.attribute),
        ])
  }
}

public func ensureContrast(_ color: RGB, against backdrop: RGB, minimum: Double) -> RGB {
  let target = minimum + 0.01
  guard color.contrast(with: backdrop) < target else { return color }
  let (hue, saturation, lightness) = color.hsl
  func candidate(_ l: Double) -> RGB { RGB(hue: hue, saturation: saturation, lightness: l) }
  func search(toward end: Double) -> RGB? {
    guard candidate(end).contrast(with: backdrop) >= target else { return nil }
    var near = lightness
    var far = end
    for _ in 0..<32 {
      let middle = (near + far) / 2
      if candidate(middle).contrast(with: backdrop) >= target { far = middle } else { near = middle }
    }
    return candidate(far)
  }
  let ends: [Double] = backdrop.relativeLuminance < 0.18 ? [1, 0] : [0, 1]
  for end in ends {
    if let adjusted = search(toward: end) { return adjusted }
  }
  let white = RGB(white: 1)
  let black = RGB(white: 0)
  return white.contrast(with: backdrop) > black.contrast(with: backdrop) ? white : black
}

extension RGB {
  init(white: Double) { self.init(white, white, white) }

  var hsl: (hue: Double, saturation: Double, lightness: Double) {
    let maximum = max(r, g, b)
    let minimum = min(r, g, b)
    let lightness = (maximum + minimum) / 2
    let delta = maximum - minimum
    guard delta > 0 else { return (0, 0, lightness) }
    let saturation = min(delta / (1 - abs(2 * lightness - 1)), 1)
    let sector: Double =
      switch maximum {
      case r: (g - b) / delta
      case g: (b - r) / delta + 2
      default: (r - g) / delta + 4
      }
    return ((sector * 60 + 360).truncatingRemainder(dividingBy: 360), saturation, lightness)
  }

  init(hue: Double, saturation: Double, lightness: Double) {
    let chroma = (1 - abs(2 * lightness - 1)) * saturation
    let sector = hue / 60
    let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
    let (r, g, b): (Double, Double, Double) =
      switch sector {
      case ..<1: (chroma, x, 0)
      case ..<2: (x, chroma, 0)
      case ..<3: (0, chroma, x)
      case ..<4: (0, x, chroma)
      case ..<5: (x, 0, chroma)
      default: (chroma, 0, x)
      }
    let offset = lightness - chroma / 2
    self.init(r + offset, g + offset, b + offset)
  }
}
