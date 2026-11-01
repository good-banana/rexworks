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
  var rightToLeftParagraph: CTParagraphStyle
  var leftToRightParagraph: CTParagraphStyle
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
    let interval = CGFloat(spaceWidth) * CGFloat(tabWidth)
    let paragraph = Self.paragraphStyle(tabInterval: interval, direction: .natural)
    let rightToLeft = Self.paragraphStyle(tabInterval: interval, direction: .rightToLeft)
    let leftToRight = Self.paragraphStyle(tabInterval: interval, direction: .leftToRight)
    let metrics = FontMetrics(
      font: font, ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font),
      attributes: [
        .init(kCTFontAttributeName as String): font,
        .init(kCTForegroundColorFromContextAttributeName as String): true,
        .init(kCTParagraphStyleAttributeName as String): paragraph,
      ], rightToLeftParagraph: rightToLeft, leftToRightParagraph: leftToRight)
    fonts[key] = metrics
    return metrics
  }

  private static func paragraphStyle(tabInterval: CGFloat, direction: CTWritingDirection) -> CTParagraphStyle {
    var interval = tabInterval
    var noStops: CFArray = [] as CFArray
    var writingDirection = direction
    return withUnsafeMutablePointer(to: &interval) { intervalPointer in
      withUnsafeMutablePointer(to: &noStops) { stopsPointer in
        withUnsafeMutablePointer(to: &writingDirection) { directionPointer in
          let settings = [
            CTParagraphStyleSetting(
              spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: intervalPointer),
            CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: stopsPointer),
            CTParagraphStyleSetting(
              spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size, value: directionPointer),
          ]
          return CTParagraphStyleCreate(settings, settings.count)
        }
      }
    }
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
