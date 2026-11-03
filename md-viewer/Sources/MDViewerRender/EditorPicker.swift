import AppKit
import CoreGraphics
import CoreText
import MDViewerCore

public struct EditorPickerContent: Equatable, Sendable {
  public var candidates: [EditorCandidate]
  public var selected: Int
  public var mode: EditMode

  public init(candidates: [EditorCandidate], selected: Int = 0, mode: EditMode) {
    self.candidates = candidates
    self.selected = min(max(selected, 0), max(candidates.count - 1, 0))
    self.mode = mode
  }
}

extension EditorKind {
  public var displayName: String {
    switch self {
    case .neovim: "Neovim"
    case .vim: "Vim"
    case .helix: "Helix"
    case .emacs: "Emacs"
    case .nano: "nano"
    case .micro: "micro"
    case .kakoune: "Kakoune"
    case .vscode: "VS Code"
    case .cursor: "Cursor"
    case .zed: "Zed"
    case .sublime: "Sublime Text"
    case .terminal: "Editor"
    }
  }
}

public struct EditorPicker {
  public static let title = "Choose an editor"
  public static let footer =
    "1-9 or arrows and Enter to choose, Tab switches the mode, Esc cancels. Saved to md-viewer's settings."
  public static let emptyMessage = "No editor found. Install one, or run md-viewer config set editor <command>"

  public static func modeRow(_ mode: EditMode) -> String {
    let beside = "beside the preview"
    let here = "in this pane"
    return mode == .split
      ? "Edit with e: \(beside) (Tab to switch to: \(here))" : "Edit with e: \(here) (Tab to switch to: \(beside))"
  }

  public static func label(_ index: Int, _ candidate: EditorCandidate) -> String {
    "\(index + 1)  \(candidate.kind.displayName)"
  }

  public static func detail(_ candidate: EditorCandidate) -> String {
    let profile = EditorProfile(kind: candidate.kind)
    if !profile.runsInTerminal { return "opens outside Rex" }
    return "\(candidate.executable)   \(profile.syncsLive ? "live preview" : "refreshes on save")"
  }

  public static func rowText(_ index: Int, _ candidate: EditorCandidate) -> String {
    "\(label(index, candidate))   \(detail(candidate))"
  }

  public let content: EditorPickerContent
  public let backingScale: CGFloat

  public init(content: EditorPickerContent, backingScale: CGFloat) {
    self.content = content
    self.backingScale = min(max(backingScale.isFinite ? backingScale : 2, 1), 4)
  }

  private func points(_ value: CGFloat) -> CGFloat { value * backingScale }

  var rowHeight: CGFloat { points(22) }
  var inset: CGFloat { points(16) }
  var textFont: CTFont { NSFont.systemFont(ofSize: points(12), weight: .regular) as CTFont }

  func footerLines(width: CGFloat) -> [String] {
    let text = content.candidates.isEmpty ? HelpOverlay.footer : Self.footer
    return wrapped(text, font: textFont, width: width - inset * 2, maximumLines: 2)
  }

  public func panel(in area: CGRect) -> CGRect {
    let width = max(min(points(560), area.width - points(16)), 0)
    let rows = max(content.candidates.count, 1)
    let modeRows = content.candidates.isEmpty ? 0 : 1.5
    let lines = 1.5 + CGFloat(rows) + modeRows + 0.5 + CGFloat(footerLines(width: width).count)
    let height = max(min(rowHeight * lines + inset * 2, area.height - points(16)), 0)
    return CGRect(
      x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
  }

  public func rowRect(_ index: Int, in area: CGRect) -> CGRect {
    let panel = panel(in: area)
    let top = panel.minY + inset + rowHeight * 1.5 + CGFloat(index) * rowHeight
    return CGRect(x: panel.minX + inset / 2, y: top, width: max(panel.width - inset, 0), height: rowHeight)
  }

  public func row(at point: CGPoint, in area: CGRect) -> Int? {
    let panel = panel(in: area)
    return content.candidates.indices.first { index in
      let rect = rowRect(index, in: area)
      return rect.contains(point) && rect.maxY <= panel.maxY
    }
  }

  public func draw(palette: RenderPalette, in area: CGRect, clip: CGRect, origin: CGPoint = .zero, bitmap: RasterBitmap)
  {
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
    let room = panel.width - inset * 2
    let keyColumn = min(panel.width * 0.32, points(150))
    func baseline(_ line: TextLine, in band: CGRect) -> CGFloat {
      (band.midY + (line.ascent - line.descent) / 2).rounded()
    }

    let title = TextLine(Self.title, font: titleFont, truncateTo: room)
    context.setFillColor(palette.statusBarText.cgColor)
    title.draw(
      in: context,
      at: CGPoint(
        x: panel.minX + inset,
        y: baseline(title, in: CGRect(x: 0, y: panel.minY + inset, width: 0, height: rowHeight))))

    var y = rowRect(0, in: area).minY
    if content.candidates.isEmpty {
      let message = TextLine(Self.emptyMessage, font: textFont, truncateTo: room)
      message.draw(
        in: context,
        at: CGPoint(x: panel.minX + inset, y: baseline(message, in: CGRect(x: 0, y: y, width: 0, height: rowHeight))))
      y += rowHeight
    } else {
      for (index, candidate) in content.candidates.enumerated() {
        let band = rowRect(index, in: area)
        if index == content.selected {
          context.setFillColor(palette.selectionFill.cgColor)
          context.addPath(
            CGPath(roundedRect: band, cornerWidth: points(4), cornerHeight: points(4), transform: nil))
          context.fillPath()
        }
        let label = TextLine(Self.label(index, candidate), font: keyFont, truncateTo: keyColumn - points(8))
        context.setFillColor(palette.link.cgColor)
        label.draw(in: context, at: CGPoint(x: panel.minX + inset, y: baseline(label, in: band)))
        let detail = TextLine(
          Self.detail(candidate), font: textFont, truncateTo: max(room - keyColumn, 0), truncation: .middle)
        context.setFillColor(palette.statusBarText.cgColor)
        detail.draw(in: context, at: CGPoint(x: panel.minX + inset + keyColumn, y: baseline(detail, in: band)))
        y = band.maxY
      }
      y += rowHeight * 0.5
      let mode = TextLine(Self.modeRow(content.mode), font: textFont, truncateTo: room)
      context.setFillColor(palette.statusBarText.cgColor)
      mode.draw(
        in: context,
        at: CGPoint(x: panel.minX + inset, y: baseline(mode, in: CGRect(x: 0, y: y, width: 0, height: rowHeight))))
      y += rowHeight
    }
    y += rowHeight * 0.5
    context.setFillColor(palette.statusMutedText.cgColor)
    for text in footerLines(width: panel.width) {
      let line = TextLine(text, font: textFont, truncateTo: room)
      line.draw(
        in: context,
        at: CGPoint(x: panel.minX + inset, y: baseline(line, in: CGRect(x: 0, y: y, width: 0, height: rowHeight))))
      y += rowHeight
    }
  }
}
