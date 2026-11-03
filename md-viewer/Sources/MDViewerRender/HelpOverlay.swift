import AppKit
import CoreGraphics
import CoreText
import MDViewerCore

public struct HelpOverlay {
  public static let title = "Keys and mouse"
  public static let footer = "Press any key to close"

  public static func entries(editMode: EditMode) -> [(keys: String, action: String)] {
    let beside = "Edit beside the preview"
    let here = "Edit in this pane"
    return [
      ("j  k  Up  Down", "Scroll three rows"),
      ("d  u", "Scroll half a view"),
      ("Space  b  PgDn  PgUp", "Scroll a view"),
      ("g  G  Home  End", "Top or bottom"),
      ("Wheel", "Scroll"),
      ("Shift-wheel, sideways wheel", "Scroll a wide block sideways"),
      ("h  l  Left  Right", "Scroll the focused block sideways"),
      ("Tab  Shift-Tab", "Move focus between links, details, code and tables"),
      ("Enter", "Follow the link, toggle details, copy the code block"),
      ("Click", "Follow links, toggle details, press Copy, open videos; with Neovim beside, jump the editor"),
      ("Drag, double-click, triple-click", "Select text, words or blocks"),
      ("y  Cmd-C", "Copy the selection as text"),
      ("Y", "Copy the selection as Markdown"),
      ("c", "Copy the focused code block"),
      ("/  Cmd-F", "Find"),
      ("n  N", "Next or previous match"),
      ("Backspace  h", "Back"),
      ("L  Shift-Backspace", "Forward"),
      ("+  -  0", "Zoom in, out or reset"),
      ("e", editMode == .split ? beside : here),
      ("E", editMode == .split ? here : beside),
      (",", "Choose the editor"),
      ("r", "Refresh: reload the file and the theme"),
      ("Esc", "Close find, clear the selection or focus"),
      ("?", "Show this help"),
      ("q  Ctrl-C", "Quit"),
    ]
  }

  public let palette: RenderPalette
  public let backingScale: CGFloat
  public let entries: [(keys: String, action: String)]

  public init(palette: RenderPalette, backingScale: CGFloat, editMode: EditMode = .split) {
    self.palette = palette
    self.backingScale = min(max(backingScale.isFinite ? backingScale : 2, 1), 4)
    entries = Self.entries(editMode: editMode)
  }

  private func points(_ value: CGFloat) -> CGFloat { value * backingScale }

  var rowHeight: CGFloat { points(20) }
  var inset: CGFloat { points(16) }
  var textFont: CTFont { NSFont.systemFont(ofSize: points(12), weight: .regular) as CTFont }

  func keyColumn(_ width: CGFloat) -> CGFloat { min(width * 0.42, points(230)) }

  func rows(width: CGFloat) -> [(keys: String, lines: [String])] {
    let room = width - keyColumn(width) - inset * 2
    return entries.map { ($0.keys, wrapped($0.action, font: textFont, width: room, maximumLines: 2)) }
  }

  public func panel(in area: CGRect) -> CGRect {
    let width = min(points(560), area.width - points(16))
    let lines = rows(width: max(width, 0)).reduce(0) { $0 + $1.lines.count }
    let height = min(rowHeight * CGFloat(lines + 3) + points(24), area.height - points(16))
    return CGRect(
      x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: max(width, 0),
      height: max(height, 0))
  }

  public func draw(in area: CGRect, clip: CGRect, origin: CGPoint = .zero, bitmap: RasterBitmap) {
    let context = bitmap.context
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: 0, y: CGFloat(bitmap.height))
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: -origin.x, y: -origin.y)
    context.clip(to: clip)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.setFillColor(palette.pageBackground.cgColor(alpha: 0.55))
    context.fill(area)
    let panel = panel(in: area)
    guard panel.width > 0, panel.height > 0 else { return }
    let radius = points(8)
    context.setFillColor(palette.statusBarBackground.cgColor)
    context.addPath(CGPath(roundedRect: panel, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
    context.setStrokeColor(palette.border.cgColor)
    context.setLineWidth(max(points(1), 1))
    context.addPath(
      CGPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.strokePath()
    context.clip(to: panel)

    let titleFont = NSFont.systemFont(ofSize: points(14), weight: .semibold) as CTFont
    let keyFont = NSFont.monospacedSystemFont(ofSize: points(12), weight: .medium) as CTFont
    let keyColumn = keyColumn(panel.width)
    var y = panel.minY + inset + rowHeight * 0.75
    context.setFillColor(palette.statusBarText.cgColor)
    TextLine(Self.title, font: titleFont).draw(in: context, at: CGPoint(x: panel.minX + inset, y: y))
    y += rowHeight * 1.25
    for row in rows(width: panel.width) {
      context.setFillColor(palette.link.cgColor)
      TextLine(row.keys, font: keyFont, truncateTo: keyColumn - points(8)).draw(
        in: context, at: CGPoint(x: panel.minX + inset, y: y))
      context.setFillColor(palette.statusBarText.cgColor)
      for line in row.lines {
        TextLine(line, font: textFont, truncateTo: panel.width - keyColumn - inset * 2).draw(
          in: context, at: CGPoint(x: panel.minX + inset + keyColumn, y: y))
        y += rowHeight
      }
    }
    context.setFillColor(palette.statusMutedText.cgColor)
    TextLine(Self.footer, font: textFont).draw(in: context, at: CGPoint(x: panel.minX + inset, y: y + rowHeight * 0.25))
  }
}

func wrapped(_ text: String, font: CTFont, width: CGFloat, maximumLines: Int) -> [String] {
  let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font]
  let string = NSAttributedString(string: text, attributes: attributes)
  let typesetter = CTTypesetterCreateWithAttributedString(string)
  let utf16 = text.utf16
  var lines: [String] = []
  var start = 0
  while start < utf16.count {
    if lines.count == maximumLines - 1 || width <= 0 {
      lines.append(String(text[String.Index(utf16Offset: start, in: text)...]))
      break
    }
    let length = max(CTTypesetterSuggestLineBreak(typesetter, start, Double(width)), 1)
    let lower = String.Index(utf16Offset: start, in: text)
    let upper = String.Index(utf16Offset: min(start + length, utf16.count), in: text)
    lines.append(String(text[lower..<upper]).trimmingCharacters(in: .whitespaces))
    start += length
  }
  return lines.isEmpty ? [""] : lines
}
