import CoreGraphics
import CryptoKit
import Foundation
import MDViewerCore

public struct MermaidTheme: Hashable, Sendable {
  public static let defaultFontFamily = "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", Helvetica, sans-serif"

  public var dark: Bool
  public var background: RGB
  public var text: RGB
  public var errorAccent: RGB
  public var fontFamily: String
  public var fontSize: CGFloat
  public var variables: [String: String]

  public init(palette: RenderPalette, fontFamily: String = Self.defaultFontFamily, fontSize: CGFloat = 14) {
    let bg = palette.pageBackground
    let tinted = { (color: RGB) in bg.mixed(with: color, 0.16) }
    let node = tinted(palette.link)
    let secondary = tinted(palette.alerts.important)
    let note = tinted(palette.alerts.warning)
    dark = palette.dark
    background = bg
    text = palette.text
    errorAccent = palette.alerts.caution
    self.fontFamily = fontFamily
    self.fontSize = fontSize
    let colors: [String: RGB] = [
      "background": bg,
      "primaryColor": node,
      "primaryBorderColor": palette.link,
      "primaryTextColor": palette.text,
      "secondaryColor": secondary,
      "secondaryBorderColor": palette.alerts.important,
      "secondaryTextColor": palette.text,
      "tertiaryColor": palette.codeBlockBackground,
      "tertiaryBorderColor": palette.border,
      "tertiaryTextColor": palette.text,
      "mainBkg": node,
      "nodeBorder": palette.link,
      "nodeTextColor": palette.text,
      "lineColor": palette.mutedText,
      "textColor": palette.text,
      "titleColor": palette.headingText,
      "edgeLabelBackground": bg,
      "clusterBkg": palette.codeBlockBackground,
      "clusterBorder": palette.border,
      "noteBkgColor": note,
      "noteBorderColor": palette.alerts.warning,
      "noteTextColor": palette.text,
      "actorBkg": node,
      "actorBorder": palette.link,
      "actorTextColor": palette.text,
      "actorLineColor": palette.mutedText,
      "signalColor": palette.text,
      "signalTextColor": palette.text,
      "labelBoxBkgColor": node,
      "labelBoxBorderColor": palette.link,
      "labelTextColor": palette.text,
      "loopTextColor": palette.text,
      "errorBkgColor": tinted(palette.alerts.caution),
      "errorTextColor": palette.alerts.caution,
    ]
    variables = colors.mapValues(\.description)
    variables["fontFamily"] = fontFamily
    variables["fontSize"] = "\(Int(fontSize.rounded()))px"
  }

  public var digest: String {
    var canonical = "dark=\(dark);"
    for key in variables.keys.sorted() {
      canonical += "\(key)=\(variables[key] ?? "");"
    }
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
