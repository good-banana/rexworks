import AppKit
import CoreGraphics
import CoreText
import MDViewerCore

enum MermaidErrorImage {
  static let title = "Unable to render rich display"
  static let maximumMessageLength = 2000
  static let padding: CGFloat = 16
  static let titleSpacing: CGFloat = 8
  static let cornerRadius: CGFloat = 6

  static let widthRange: ClosedRange<CGFloat> = 120...4096

  static func make(_ failure: MermaidFailure, theme: MermaidTheme, width: CGFloat, scale: CGFloat) -> MermaidDiagram? {
    let width = min(max(width, widthRange.lowerBound), widthRange.upperBound)
    let textWidth = width - padding * 2
    let titleText = attributed(
      title, font: NSFont.systemFont(ofSize: 14, weight: .semibold), color: theme.text)
    let detailText = attributed(
      String(failure.message.prefix(maximumMessageLength)),
      font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), color: theme.text)
    let titleHeight = height(of: titleText, width: textWidth)
    let detailHeight = height(of: detailText, width: textWidth)
    let size = CGSize(width: width, height: (padding * 2 + titleHeight + titleSpacing + detailHeight).rounded(.up))
    let pixelWidth = Int((size.width * scale).rounded(.up))
    let pixelHeight = Int((size.height * scale).rounded(.up))
    guard
      let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(cgColor(theme.background))
    context.fill(CGRect(origin: .zero, size: size))

    let box = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
    let path = CGPath(roundedRect: box, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.addPath(path)
    context.setFillColor(cgColor(theme.background.mixed(with: theme.errorAccent, 0.1)))
    context.fillPath()
    context.addPath(path)
    context.setStrokeColor(cgColor(theme.background.mixed(with: theme.errorAccent, 0.6)))
    context.setLineWidth(1)
    context.strokePath()

    let titleTop = size.height - padding
    draw(titleText, in: CGRect(x: padding, y: titleTop - titleHeight, width: textWidth, height: titleHeight), context)
    let detailTop = titleTop - titleHeight - titleSpacing
    draw(
      detailText, in: CGRect(x: padding, y: detailTop - detailHeight, width: textWidth, height: detailHeight), context)
    guard let image = context.makeImage() else { return nil }
    return MermaidDiagram(size: size, image: image, failure: failure)
  }

  private static func attributed(_ string: String, font: NSFont, color: RGB) -> NSAttributedString {
    NSAttributedString(
      string: string,
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(color),
      ])
  }

  private static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
    let framesetter = CTFramesetterCreateWithAttributedString(text)
    let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
      framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
    return fitted.height.rounded(.up)
  }

  private static func draw(_ text: NSAttributedString, in rect: CGRect, _ context: CGContext) {
    let framesetter = CTFramesetterCreateWithAttributedString(text)
    let frame = CTFramesetterCreateFrame(
      framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, context)
  }

  static func cgColor(_ color: RGB) -> CGColor {
    CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)
  }
}
