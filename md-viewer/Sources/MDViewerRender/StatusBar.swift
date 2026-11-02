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
  public var findField: String?

  public init(
    fileName: String, folder: String? = nil, progress: ScrollProgress, message: StatusMessage? = nil,
    hint: String? = nil, findField: String? = nil
  ) {
    self.fileName = fileName
    self.folder = folder
    self.progress = progress
    self.message = message
    self.hint = hint
    self.findField = findField
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

  public static let keyHints = "/ find   r refresh   q quit   ? help"

  private func points(_ value: CGFloat) -> CGFloat { value * backingScale }

  struct Metrics {
    var body: CGRect
    var fontSize: CGFloat
    var padding: CGFloat
    var gap: CGFloat
    var hintFont: CTFont
    var hints: TextLine
    var hintsX: CGFloat
    var showsHints: Bool
  }

  func metrics(in rect: CGRect) -> Metrics {
    let trackHeight = max(points(2).rounded(), 1)
    let body = CGRect(x: rect.minX, y: rect.minY + trackHeight, width: rect.width, height: rect.height - trackHeight)
    let fontSize = min(max(body.height * 0.5, points(11)), points(13))
    let padding = points(10)
    let hintFont = NSFont.systemFont(ofSize: fontSize * 0.92, weight: .regular) as CTFont
    let hints = TextLine(Self.keyHints, font: hintFont)
    return Metrics(
      body: body, fontSize: fontSize, padding: padding, gap: points(12), hintFont: hintFont, hints: hints,
      hintsX: rect.maxX - padding - hints.width, showsHints: hints.width <= rect.width - padding * 2)
  }

  public func keyHintsRect(in rect: CGRect) -> CGRect {
    let metrics = metrics(in: rect)
    guard metrics.showsHints else { return .null }
    return CGRect(x: metrics.hintsX, y: metrics.body.minY, width: metrics.hints.width, height: metrics.body.height)
  }

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

    let metrics = metrics(in: rect)
    let body = metrics.body
    let fontSize = metrics.fontSize
    let padding = metrics.padding
    let gap = metrics.gap
    let textColor = palette.statusBarText
    func baseline(_ line: TextLine) -> CGFloat { (body.midY + (line.ascent - line.descent) / 2).rounded() }

    var right = rect.maxX - padding
    if metrics.showsHints {
      context.setFillColor(palette.statusHintText.cgColor)
      metrics.hints.draw(in: context, at: CGPoint(x: metrics.hintsX, y: baseline(metrics.hints)))
      right = metrics.hintsX - gap
    }
    if let message = content.message {
      let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium) as CTFont
      let line = TextLine(
        message.text, font: font, truncateTo: max(min(rect.width * 0.4, right - rect.minX - padding - points(40)), 0))
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

    if let query = content.findField {
      let geometry = findField(query, right: right, in: rect)
      let field = geometry.field
      context.setFillColor(palette.pageBackground.cgColor)
      context.addPath(CGPath(roundedRect: field, cornerWidth: points(4), cornerHeight: points(4), transform: nil))
      context.fillPath()
      context.setStrokeColor(palette.focusOutline.cgColor)
      context.setLineWidth(geometry.border)
      context.addPath(
        CGPath(
          roundedRect: field.insetBy(dx: geometry.border / 2, dy: geometry.border / 2), cornerWidth: points(4),
          cornerHeight: points(4), transform: nil))
      context.strokePath()
      Glyphs(context: context, hairline: max(1, backingScale.rounded())).magnifier(
        in: geometry.icon, color: palette.statusMutedText.cgColor)
      context.setFillColor(textColor.cgColor)
      geometry.line.draw(in: context, at: CGPoint(x: geometry.textX, y: geometry.baseline))
      context.fill(geometry.caret)
      right = field.minX - gap
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
        let folderLine = TextLine(folder, font: folderFont, truncateTo: folderRoom, truncation: .middle)
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
      let line = TextLine(hint, font: metrics.hintFont)
      if line.width <= right - x - gap {
        context.setFillColor(palette.statusHintText.cgColor)
        line.draw(in: context, at: CGPoint(x: right - line.width, y: baseline(line)))
      }
    }
  }

  struct FindFieldGeometry {
    var field: CGRect
    var icon: CGRect
    var line: TextLine
    var textX: CGFloat
    var baseline: CGFloat
    var caret: CGRect
    var border: CGFloat
  }

  func findField(_ query: String, right: CGFloat, in rect: CGRect) -> FindFieldGeometry {
    let metrics = metrics(in: rect)
    let body = metrics.body
    let fontSize = metrics.fontSize
    let font = NSFont.systemFont(ofSize: fontSize, weight: .regular) as CTFont
    let iconSize = fontSize * 0.8
    let inner = points(6)
    let caretWidth = max(points(1), 1)
    let border = max(points(1), 1)
    let maximumWidth = max(rect.width * 0.45, points(80))
    let textRoom = maximumWidth - inner * 3 - iconSize - caretWidth
    let line = TextLine(query, font: font, truncateTo: max(textRoom, 0), truncation: .start)
    let fieldWidth = min(max(inner * 3 + iconSize + line.width + caretWidth, rect.width * 0.25), maximumWidth)
    let fieldHeight = min(body.height - points(4), fontSize * 1.6)
    let field = CGRect(
      x: max(right - fieldWidth, rect.minX + metrics.padding), y: (body.midY - fieldHeight / 2).rounded(),
      width: fieldWidth, height: fieldHeight)
    let icon = CGRect(x: field.minX + inner, y: body.midY - iconSize / 2, width: iconSize, height: iconSize)
    let textX = icon.maxX + inner
    let ascent = CTFontGetAscent(font)
    let descent = CTFontGetDescent(font)
    let baseline = (body.midY + (ascent - descent) / 2).rounded()
    let inside = field.insetBy(dx: 0, dy: border + max(points(2), 1))
    let top = max(baseline - ascent, inside.minY)
    let bottom = min(baseline + descent, inside.maxY)
    let caret = CGRect(
      x: textX + line.width + points(1), y: top, width: caretWidth, height: max(bottom - top, 1))
    return FindFieldGeometry(
      field: field, icon: icon, line: line, textX: textX, baseline: baseline, caret: caret, border: border)
  }
}
