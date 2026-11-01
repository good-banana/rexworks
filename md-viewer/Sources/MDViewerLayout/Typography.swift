import CoreGraphics

public enum FontWeight: Hashable, Sendable {
  case regular, medium, semibold, bold
}

public struct Typography: Hashable, Sendable {
  public static let defaultBodySize: CGFloat = 15

  public var bodySize: CGFloat
  public var zoom: CGFloat
  public var backingScale: CGFloat

  public var codeScale: CGFloat = 0.85
  public var keyboardScale: CGFloat = 0.6875
  public var smallScale: CGFloat = 0.9
  public var scriptScale: CGFloat = 0.75
  public var footnoteScale: CGFloat = 0.75
  public var frontMatterScale: CGFloat = 0.75
  public var tableScale: CGFloat = 14.0 / 15.0
  public var headingScales: [CGFloat] = [2, 1.5, 1.25, 1, 0.875, 0.85]
  public var headingWeights: [FontWeight] = Array(repeating: .semibold, count: 6)
  public var strongWeight: FontWeight = .semibold
  public var alertTitleWeight: FontWeight = .medium

  public var bodyLineHeight: CGFloat = 1.5
  public var headingLineHeight: CGFloat = 1.25
  public var codeLineHeight: CGFloat = 1.45
  public var frontMatterLineHeight: CGFloat = 1.4

  public var pageMarginTop: CGFloat = 1.5
  public var pageMarginSide: CGFloat = 2
  public var pageMarginBottom: CGFloat = 2
  public var blockSpacing: CGFloat = 1
  public var headingSpacingTop: CGFloat = 1.5
  public var headingRulePadding: CGFloat = 0.3
  public var listIndent: CGFloat = 2
  public var listItemSpacing: CGFloat = 0.25
  public var listMarkerGap: CGFloat = 0.4
  public var taskBoxSize: CGFloat = 0.8125
  public var taskBoxOffset: CGFloat = 1.4
  public var codePadding: CGFloat = 1
  public var cornerRadius: CGFloat = 0.375
  public var inlineCodePadding = CGSize(width: 0.4, height: 0.2)
  public var keyboardPadding = CGSize(width: 0.3125, height: 0.1875)
  public var tableCellPadding = CGSize(width: 0.8125, height: 0.375)
  public var blockquotePadding: CGFloat = 1
  public var barWidth: CGFloat = 0.25
  public var alertPadding = CGSize(width: 1, height: 0.5)
  public var alertTitleGap: CGFloat = 0.5
  public var alertIconSize: CGFloat = 1
  public var alertIconGap: CGFloat = 0.5
  public var frontMatterPadding = CGSize(width: 0.875, height: 0.5)
  public var frontMatterBarWidth: CGFloat = 0.1875
  public var frontMatterColumnGap: CGFloat = 1
  public var thematicBreakHeight: CGFloat = 0.25
  public var thematicBreakSpacing: CGFloat = 1.5
  public var detailsMarkerWidth: CGFloat = 1.1
  public var detailsMarkerSize: CGFloat = 0.6
  public var copyButtonSize: CGFloat = 1.75
  public var copyButtonInset: CGFloat = 0.5
  public var footnoteIndent: CGFloat = 1
  public var imagePlaceholderSize = CGSize(width: 1.25, height: 1.25)
  public var diagramPlaceholderHeight: CGFloat = 10
  public var hairline: CGFloat = 1
  public var tabWidth: Int = 8

  public static let bodySizeRange: ClosedRange<CGFloat> = 6...72
  public static let zoomRange: ClosedRange<CGFloat> = 0.25...5
  public static let backingScaleRange: ClosedRange<CGFloat> = 1...4

  public init(bodySize: CGFloat = Typography.defaultBodySize, zoom: CGFloat = 1, backingScale: CGFloat = 2) {
    self.bodySize = Self.clamp(bodySize, Self.bodySizeRange, fallback: Self.defaultBodySize)
    self.zoom = Self.clamp(zoom, Self.zoomRange, fallback: 1)
    self.backingScale = Self.clamp(backingScale, Self.backingScaleRange, fallback: 2)
  }

  static func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
    value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
  }

  public var scale: CGFloat {
    Self.clamp(backingScale, Self.backingScaleRange, fallback: 2) * Self.clamp(zoom, Self.zoomRange, fallback: 1)
  }

  public var bodyPixelSize: CGFloat { Self.clamp(bodySize, Self.bodySizeRange, fallback: Self.defaultBodySize) * scale }

  public func pixels(em: CGFloat) -> CGFloat { em * bodyPixelSize }

  public func pixels(cssPoints: CGFloat) -> CGFloat { cssPoints * scale }

  public func headingScale(_ level: Int) -> CGFloat { headingScales[min(max(level, 1), 6) - 1] }

  public func headingWeight(_ level: Int) -> FontWeight { headingWeights[min(max(level, 1), 6) - 1] }

  public static func backingScale(cellPixelHeight: CGFloat, screenScale: CGFloat?) -> CGFloat {
    if let screenScale, screenScale.isFinite, screenScale > 0 {
      return clamp(screenScale, backingScaleRange, fallback: 2)
    }
    return cellPixelHeight >= 24 ? 2 : 1
  }
}
