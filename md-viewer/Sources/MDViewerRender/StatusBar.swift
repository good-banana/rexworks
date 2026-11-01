import AppKit
import CoreGraphics
import CoreText
import MDViewerCore

public struct ScrollProgress: Hashable, Sendable {
  public var start: CGFloat
  public var fraction: CGFloat

  public init(start: CGFloat, fraction: CGFloat) {
    self.start = min(max(start, 0), 1)
    self.fraction = min(max(fraction, 0), 1 - self.start)
  }

  public init(offset: CGFloat, viewport: CGFloat, content: CGFloat) {
    guard content > 0, viewport > 0 else {
      self.init(start: 0, fraction: 1)
      return
    }
    self.init(start: offset / content, fraction: viewport / content)
  }
}

public struct StatusMessage: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case info, find, success, error
  }

  public var text: String
  public var kind: Kind

  public init(_ text: String, kind: Kind = .info) {
    self.text = text
    self.kind = kind
  }
}

public struct StatusBarContent: Hashable, Sendable {
  public var fileName: String
  public var folder: String?
  public var progress: ScrollProgress
  public var message: StatusMessage?
  public var hint: String?

  public init(
    fileName: String, folder: String? = nil, progress: ScrollProgress, message: StatusMessage? = nil,
    hint: String? = nil
  ) {
    self.fileName = fileName
    self.folder = folder
    self.progress = progress
    self.message = message
    self.hint = hint
  }
}

public struct StatusBar {
  public static let preferredPointHeight: CGFloat = 22
  public static let minimumPointHeight: CGFloat = 16

  public let palette: RenderPalette
  public let backingScale: CGFloat

  public init(palette: RenderPalette, backingScale: CGFloat) {
    self.palette = palette
    self.backingScale = min(max(backingScale.isFinite ? backingScale : 2, 1), 4)
  }

  public static func height(cellPixelHeight: CGFloat, backingScale: CGFloat) -> CGFloat {
    let scale = min(max(backingScale.isFinite ? backingScale : 2, 1), 4)
    let preferred = preferredPointHeight * scale
    guard cellPixelHeight.isFinite, cellPixelHeight > 0 else { return preferred.rounded() }
    let rows = max(
      (preferred / cellPixelHeight).rounded(), (minimumPointHeight * scale / cellPixelHeight).rounded(.up), 1)
    return rows * cellPixelHeight
  }

  private func points(_ value: CGFloat) -> CGFloat { value * backingScale }

  public func draw(_ content: StatusBarContent, in rect: CGRect, bitmap: RasterBitmap) {
    let context = bitmap.context
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: 0, y: CGFloat(bitmap.height))
    context.scaleBy(x: 1, y: -1)
    context.clip(to: rect)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    draw(content, in: rect, context: context)
  }

  func draw(_ content: StatusBarContent, in rect: CGRect, context: CGContext) {
    context.setFillColor(palette.statusBarBackground.cgColor)
    context.fill(rect)

    let trackHeight = max(points(2).rounded(), 1)
    context.setFillColor(palette.progressTrack.cgColor)
    context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: trackHeight))
    let minimumThumb = min(points(14), rect.width)
    let thumbWidth = max(rect.width * content.progress.fraction, minimumThumb)
    let thumbX = rect.minX + min(rect.width * content.progress.start, rect.width - thumbWidth)
    let thumb = CGRect(x: thumbX, y: rect.minY, width: thumbWidth, height: trackHeight)
    context.setFillColor(palette.progressFill.cgColor)
    context.addPath(
      CGPath(roundedRect: thumb, cornerWidth: trackHeight / 2, cornerHeight: trackHeight / 2, transform: nil))
    context.fillPath()

    let body = CGRect(x: rect.minX, y: rect.minY + trackHeight, width: rect.width, height: rect.height - trackHeight)
    let fontSize = min(max(body.height * 0.5, points(11)), points(13))
    let padding = points(10)
    let gap = points(12)
    let textColor = palette.statusBarText
    func baseline(_ line: TextLine) -> CGFloat { (body.midY + (line.ascent - line.descent) / 2).rounded() }

    var right = rect.maxX - padding
    if let message = content.message {
      let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium) as CTFont
      let line = TextLine(message.text, font: font, truncateTo: rect.width * 0.4)
      let color: RGB =
        switch message.kind {
        case .info, .find: textColor
        case .success: palette.alerts.tip
        case .error: palette.alerts.caution
        }
      let glyphs = Glyphs(context: context, hairline: max(1, backingScale.rounded()))
      let iconSize = fontSize * 0.8
      let hasIcon = message.kind != .info
      let pillWidth = line.width + points(8) * 2 + (hasIcon ? iconSize + points(5) : 0)
      let pillHeight = min(body.height - points(4), fontSize * 1.6)
      let pill = CGRect(
        x: right - pillWidth, y: (body.midY - pillHeight / 2).rounded(), width: pillWidth, height: pillHeight)
      context.setFillColor(palette.progressTrack.cgColor(alpha: 0.6))
      context.addPath(
        CGPath(roundedRect: pill, cornerWidth: pillHeight / 2, cornerHeight: pillHeight / 2, transform: nil))
      context.fillPath()
      var x = pill.minX + points(8)
      if hasIcon {
        let icon = CGRect(x: x, y: body.midY - iconSize / 2, width: iconSize, height: iconSize)
        switch message.kind {
        case .find: glyphs.magnifier(in: icon, color: color.cgColor)
        case .success: glyphs.check(in: icon, color: color.cgColor)
        case .error: glyphs.alertIcon(.caution, in: icon, color: color.cgColor)
        case .info: break
        }
        x = icon.maxX + points(5)
      }
      context.setFillColor(color.cgColor)
      line.draw(in: context, at: CGPoint(x: x, y: baseline(line)))
      right = pill.minX - gap
    }

    let nameFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold) as CTFont
    let folderFont = NSFont.systemFont(ofSize: fontSize, weight: .regular) as CTFont
    let available = max(right - (rect.minX + padding), 0)
    let name = TextLine(content.fileName, font: nameFont, truncateTo: available, truncation: .middle)
    var x = rect.minX + padding
    if let folder = content.folder, !folder.isEmpty {
      let separator = TextLine(" \u{203A} ", font: folderFont)
      let folderRoom = available - name.width - separator.width
      if folderRoom >= points(24) {
        let folderLine = TextLine(folder, font: folderFont, truncateTo: folderRoom, truncation: .start)
        context.setFillColor(palette.statusMutedText.cgColor)
        folderLine.draw(in: context, at: CGPoint(x: x, y: baseline(folderLine)))
        x += folderLine.width
        context.setFillColor(palette.statusHintText.cgColor)
        separator.draw(in: context, at: CGPoint(x: x, y: baseline(separator)))
        x += separator.width
      }
    }
    context.setFillColor(textColor.cgColor)
    name.draw(in: context, at: CGPoint(x: x, y: baseline(name)))
    x += name.width

    if let hint = content.hint, !hint.isEmpty {
      let hintFont = NSFont.systemFont(ofSize: fontSize * 0.92, weight: .regular) as CTFont
      let line = TextLine(hint, font: hintFont)
      if line.width <= right - x - gap {
        context.setFillColor(palette.statusHintText.cgColor)
        line.draw(in: context, at: CGPoint(x: right - line.width, y: baseline(line)))
      }
    }
  }
}
