import AppKit
import CoreText

struct FontKey: Hashable {
  var size: CGFloat
  var weight: FontWeight
  var italic: Bool
  var monospaced: Bool
}

struct FontMetrics {
  var font: CTFont
  var ascent: CGFloat
  var descent: CGFloat
  var attributes: [NSAttributedString.Key: Any]
}

final class FontCache {
  private var fonts: [FontKey: FontMetrics] = [:]
  private let tabWidth: Int

  init(tabWidth: Int) {
    self.tabWidth = tabWidth
  }

  func metrics(_ key: FontKey) -> FontMetrics {
    if let cached = fonts[key] { return cached }
    let font = Self.makeFont(key)
    let space = NSAttributedString(string: " ", attributes: [.init(kCTFontAttributeName as String): font])
    let spaceWidth = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(space), nil, nil, nil)
    var interval = CGFloat(spaceWidth) * CGFloat(tabWidth)
    var noStops: CFArray = [] as CFArray
    let paragraph = withUnsafeMutablePointer(to: &interval) { intervalPointer in
      withUnsafeMutablePointer(to: &noStops) { stopsPointer in
        let settings = [
          CTParagraphStyleSetting(
            spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: intervalPointer),
          CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: stopsPointer),
        ]
        return CTParagraphStyleCreate(settings, settings.count)
      }
    }
    let metrics = FontMetrics(
      font: font, ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font),
      attributes: [
        .init(kCTFontAttributeName as String): font,
        .init(kCTForegroundColorFromContextAttributeName as String): true,
        .init(kCTParagraphStyleAttributeName as String): paragraph,
      ])
    fonts[key] = metrics
    return metrics
  }

  private static func makeFont(_ key: FontKey) -> CTFont {
    let weight: NSFont.Weight =
      switch key.weight {
      case .regular: .regular
      case .medium: .medium
      case .semibold: .semibold
      case .bold: .bold
      }
    let base: CTFont =
      key.monospaced
      ? NSFont.monospacedSystemFont(ofSize: key.size, weight: weight) as CTFont
      : NSFont.systemFont(ofSize: key.size, weight: weight) as CTFont
    guard key.italic else { return base }
    return CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .traitItalic, .traitItalic) ?? base
  }
}
