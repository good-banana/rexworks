import AppKit
import CoreText

public enum CopyButtonMetrics {
  public static let copyLabel = "Copy"
  public static let copiedLabel = "Copied"
  public static let labelScale: CGFloat = 0.75
  public static let iconScale: CGFloat = 0.8
  public static let gapScale: CGFloat = 0.35
  public static let paddingScale: CGFloat = 0.55

  public static func labelFont(_ typography: Typography) -> CTFont {
    NSFont.systemFont(ofSize: typography.pixels(em: labelScale), weight: .medium) as CTFont
  }

  public static func labelWidth(_ label: String, typography: Typography) -> CGFloat {
    let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): labelFont(typography)]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  }

  public static func width(_ typography: Typography) -> CGFloat {
    let content =
      typography.pixels(em: paddingScale) * 2 + typography.pixels(em: iconScale) + typography.pixels(em: gapScale)
    let widest = max(labelWidth(copyLabel, typography: typography), labelWidth(copiedLabel, typography: typography))
    return max(typography.pixels(em: typography.copyButtonSize), (content + widest).rounded(.up))
  }
}
