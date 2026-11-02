import AppKit
import CoreGraphics
import CoreText
import MDViewerCore

public struct HelpOverlay {
  public static let title = "Keys and mouse"
  public static let footer = "Press any key to close"

  public static let entries: [(keys: String, action: String)] = [
    ("j  k  Up  Down", "Scroll three rows"),
    ("d  u", "Scroll half a view"),
    ("Space  b  PgDn  PgUp", "Scroll a view"),
    ("g  G  Home  End", "Top or bottom"),
    ("Wheel", "Scroll"),
    ("Shift-wheel, sideways wheel", "Scroll a wide block sideways"),
    ("h  l  Left  Right", "Scroll the focused block sideways"),
    ("Tab  Shift-Tab", "Move focus between links, details, code and tables"),
    ("Enter", "Follow the link, toggle details, copy the code block"),
    ("Click", "Follow links, toggle details, press Copy, open videos"),
    ("Drag, double-click, triple-click", "Select text, words or blocks"),
    ("y  Cmd-C", "Copy the selection as text"),
    ("Y", "Copy the selection as Markdown"),
    ("c", "Copy the focused code block"),
    ("/  Cmd-F", "Find"),
    ("n  N", "Next or previous match"),
    ("Backspace  h", "Back"),
    ("L  Shift-Backspace", "Forward"),
    ("+  -  0", "Zoom in, out or reset"),
    ("r", "Refresh: reload the file and the theme"),
    ("Esc", "Close find, clear the selection or focus"),
    ("?", "Show this help"),
    ("q  Ctrl-C", "Quit"),
  ]

  public let palette: RenderPalette
  public let backingScale: CGFloat

  public init(palette: RenderPalette, backingScale: CGFloat) {
    self.palette = palette
    self.backingScale = min(max(backingScale.isFinite ? backingScale : 2, 1), 4)
  }

  private func points(_ value: CGFloat) -> CGFloat { value * backingScale }

  public func panel(in area: CGRect) -> CGRect {
    let width = min(points(560), area.width - points(16))
    let rowHeight = points(20)
    let height = min(rowHeight * CGFloat(Self.entries.count + 3) + points(24), area.height - points(16))
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

    let rowHeight = points(20)
    let inset = points(16)
    let titleFont = NSFont.systemFont(ofSize: points(14), weight: .semibold) as CTFont
    let keyFont = NSFont.monospacedSystemFont(ofSize: points(12), weight: .medium) as CTFont
    let textFont = NSFont.systemFont(ofSize: points(12), weight: .regular) as CTFont
    let keyColumn = min(panel.width * 0.42, points(230))
    var y = panel.minY + inset + rowHeight * 0.75
    context.setFillColor(palette.statusBarText.cgColor)
    TextLine(Self.title, font: titleFont).draw(in: context, at: CGPoint(x: panel.minX + inset, y: y))
    y += rowHeight * 1.25
    for entry in Self.entries {
      context.setFillColor(palette.link.cgColor)
      TextLine(entry.keys, font: keyFont, truncateTo: keyColumn - points(8)).draw(
        in: context, at: CGPoint(x: panel.minX + inset, y: y))
      context.setFillColor(palette.statusBarText.cgColor)
      TextLine(entry.action, font: textFont, truncateTo: panel.width - keyColumn - inset * 2).draw(
        in: context, at: CGPoint(x: panel.minX + inset + keyColumn, y: y))
      y += rowHeight
    }
    context.setFillColor(palette.statusMutedText.cgColor)
    TextLine(Self.footer, font: textFont).draw(in: context, at: CGPoint(x: panel.minX + inset, y: y + rowHeight * 0.25))
  }
}
