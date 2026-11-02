import AppKit
import CoreGraphics
import CoreText
import MDViewerCore
import MDViewerLayout

struct Painter {
  let layout: PageLayout
  let index: SceneIndex
  let assets: RenderAssets
  let highlights: [BlockID: HighlightResult]
  let colors: ColorTable
  let typography: Typography
  let context: CGContext
  let visible: CGRect
  let overlay: RenderOverlay
  let hairline: CGFloat

  init(rasterizer: Rasterizer, context: CGContext, visible: CGRect, overlay: RenderOverlay) {
    layout = rasterizer.layout
    index = rasterizer.index
    assets = rasterizer.assets
    highlights = rasterizer.highlights
    colors = ColorTable(rasterizer.palette)
    typography = layout.prepared.typography
    self.context = context
    self.overlay = overlay
    hairline = max(1, typography.pixels(cssPoints: typography.hairline).rounded())
    let margin = typography.pixels(em: 1)
    self.visible = visible.insetBy(dx: -margin, dy: -margin)
  }

  func em(_ value: CGFloat) -> CGFloat { typography.pixels(em: value) }

  func css(_ value: CGFloat) -> CGFloat { typography.pixels(cssPoints: value) }

  func paint() {
    context.setFillColor(colors(\.pageBackground))
    context.fill(visible)
    for (position, decoration) in layout.decorations.enumerated()
    where isVisible(decoration.rect, region: decoration.region) {
      inRegion(decoration.region) { draw(decoration, at: position) }
    }
    for image in layout.images where isVisible(image.rect, region: image.region) {
      inRegion(image.region) { draw(image) }
    }
    paintHighlights()
    paintText()
    for placed in layout.labels {
      let label = layout.prepared.labels[placed.label]
      let bounds = CGRect(
        x: placed.origin.x, y: placed.origin.y - label.ascent, width: label.width, height: label.ascent + label.descent)
      guard isVisible(bounds, region: placed.region) else { continue }
      inRegion(placed.region) {
        context.setFillColor(colors(label.color))
        context.textPosition = placed.origin
        CTLineDraw(label.line, context)
      }
    }
    for region in layout.regions where region.maxOffset > 0 && visible.intersects(region.rect) {
      ScrollChrome(painter: self).draw(region)
    }
    paintCopyButton()
    paintFocus()
  }

  func isVisible(_ rect: CGRect, region: BlockID?) -> Bool {
    guard let region, let scroll = layout.region(region) else { return visible.intersects(rect) }
    let shown = rect.offsetBy(dx: -scroll.offset, dy: 0)
    return visible.intersects(shown) && scroll.rect.intersects(shown)
  }

  func inRegion(_ region: BlockID?, _ body: () -> Void) {
    guard let region, let scroll = layout.region(region) else { return body() }
    context.saveGState()
    context.clip(to: scroll.rect)
    context.translateBy(x: -scroll.offset, y: 0)
    body()
    context.restoreGState()
  }

  func fill(_ rect: CGRect, _ color: CGColor, radius: CGFloat = 0) {
    context.setFillColor(color)
    if radius > 0 {
      let clamped = min(radius, rect.width / 2, rect.height / 2)
      context.addPath(CGPath(roundedRect: rect, cornerWidth: clamped, cornerHeight: clamped, transform: nil))
      context.fillPath()
    } else {
      context.fill(rect)
    }
  }

  func stroke(_ rect: CGRect, _ color: CGColor, width: CGFloat, radius: CGFloat) {
    let inset = rect.insetBy(dx: width / 2, dy: width / 2)
    guard inset.width > 0, inset.height > 0 else { return }
    let clamped = max(min(radius - width / 2, inset.width / 2, inset.height / 2), 0)
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.addPath(CGPath(roundedRect: inset, cornerWidth: clamped, cornerHeight: clamped, transform: nil))
    context.strokePath()
  }

  private func draw(_ decoration: Decoration, at position: Int) {
    let rect = decoration.rect
    let radius = decoration.cornerRadius
    switch decoration.kind {
    case .inlineBox(.code):
      fill(rect, colors(\.inlineCodeBackground), radius: radius)
    case .inlineBox(.keyboard):
      fill(rect, colors(\.inlineCodeBackground), radius: radius)
      stroke(rect, colors(\.border), width: hairline, radius: radius)
      context.saveGState()
      context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
      context.clip()
      fill(CGRect(x: rect.minX, y: rect.maxY - hairline * 2, width: rect.width, height: hairline * 2), colors(\.border))
      context.restoreGState()
    case .inlineBox(.mark):
      fill(rect, colors(\.markHighlight), radius: radius)
    case .codeBlockBackground:
      fill(rect, colors(\.codeBlockBackground), radius: radius)
    case .headingRule, .footnoteSeparator, .thematicBreak:
      fill(rect, colors(\.border), radius: radius)
    case .blockquoteBar:
      fill(rect, colors(\.blockquoteBar))
    case .alertBar(let kind):
      fill(rect, colors(colors.palette.alert(kind)))
    case .alertIcon(let kind):
      Glyphs(context: context, hairline: hairline).alertIcon(kind, in: rect, color: colors(colors.palette.alert(kind)))
    case .tableHeaderFill:
      fill(rect, colors(\.tableHeaderFill))
      fill(CGRect(x: rect.minX, y: rect.maxY - hairline, width: rect.width, height: hairline * 2), colors(\.border))
    case .tableStripe:
      fill(rect, colors(\.tableStripe))
    case .tableCellBorder:
      let edges = index.cellEdges[position] ?? SceneIndex.CellEdges(right: true, bottom: true)
      context.setFillColor(colors(\.border))
      context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: hairline))
      context.fill(CGRect(x: rect.minX, y: rect.minY, width: hairline, height: rect.height))
      if edges.right {
        context.fill(CGRect(x: rect.maxX - hairline, y: rect.minY, width: hairline, height: rect.height))
      }
      if edges.bottom {
        context.fill(CGRect(x: rect.minX, y: rect.maxY - hairline, width: rect.width, height: hairline))
      }
    case .frontMatterBackground:
      fill(rect, colors(\.frontmatterBackground), radius: radius)
    case .frontMatterBar:
      context.saveGState()
      if let box = index.frontMatterBoxes.first(where: {
        abs($0.rect.minX - rect.minX) < 0.5 && abs($0.rect.minY - rect.minY) < 0.5
      }) {
        context.addPath(
          CGPath(roundedRect: box.rect, cornerWidth: box.cornerRadius, cornerHeight: box.cornerRadius, transform: nil))
        context.clip()
      }
      fill(rect, colors(\.frontmatterBar))
      context.restoreGState()
    case .taskBox(let checked):
      Glyphs(context: context, hairline: hairline).taskBox(
        rect, checked: checked, radius: radius, fill: colors(\.link), mark: colors(\.pageBackground),
        outline: colors(\.mutedText), background: colors(\.pageBackground))
    case .disclosure(let expanded):
      Glyphs(context: context, hairline: hairline).disclosure(rect, expanded: expanded, color: colors(\.text))
    case .copyButton:
      break
    }
  }

  private func draw(_ image: ImageBox) {
    let radius = em(typography.cornerRadius)
    switch image.content {
    case .image(let source):
      if let picture = assets.image(source) {
        drawImage(picture, in: image.rect)
      } else {
        fill(image.rect, colors(\.inlineCodeBackground), radius: radius)
        stroke(image.rect, colors(\.border), width: hairline, radius: radius)
        Glyphs(context: context, hairline: hairline).picture(in: image.rect, color: colors(\.mutedText))
      }
    case .diagram(let code):
      if let picture = assets.diagram(code) {
        drawImage(picture, in: image.rect)
      } else {
        fill(image.rect, colors(\.codeBlockBackground), radius: radius)
        let font = NSFont.systemFont(ofSize: em(0.8), weight: .medium) as CTFont
        let line = TextLine("Mermaid diagram", font: font)
        context.setFillColor(colors(\.mutedText))
        line.draw(
          in: context,
          at: CGPoint(x: image.rect.midX - line.width / 2, y: image.rect.midY + (line.ascent - line.descent) / 2))
      }
    }
  }

  private func drawImage(_ image: CGImage, in rect: CGRect) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
  }

  private func paintHighlights() {
    for (position, match) in overlay.findMatches.enumerated() {
      let color = position == overlay.currentMatch ? colors(\.currentMatchHighlight) : colors(\.findHighlight)
      if !match.rects.isEmpty,
        !match.rects.contains(where: { $0.rect.maxY >= visible.minY && $0.rect.minY <= visible.maxY })
      {
        continue
      }
      for highlight in layout.rects(for: match.range) where visible.intersects(highlight.rect) {
        fill(highlight.rect, color, radius: css(2))
      }
    }
    if let selection = overlay.selection, !selection.isEmpty {
      for highlight in layout.rects(for: selection) where visible.intersects(highlight.rect) {
        fill(highlight.rect, colors(\.selectionFill))
      }
    }
  }

  private func paintText() {
    let fragments = layout.fragments
    let segments = layout.prepared.segments
    for (position, fragment) in fragments.enumerated() {
      let bounds = CGRect(
        x: fragment.minX, y: fragment.lineTop, width: fragment.maxX - fragment.minX,
        height: fragment.lineBottom - fragment.lineTop)
      guard isVisible(bounds, region: fragment.region) else { continue }
      let segment = segments[fragment.segment]
      inRegion(fragment.region) {
        if fragment.isClipped {
          context.saveGState()
          context.clip(
            to: CGRect(
              x: fragment.minX, y: fragment.lineTop - bounds.height, width: bounds.width, height: bounds.height * 3))
        }
        if segment.style.color == .code, let tokens = tokens(for: fragment) {
          drawTokens(segment, fragment: fragment, line: tokens.line, spans: tokens.spans)
        } else {
          context.setFillColor(colors(segment.style.color))
          context.textPosition = fragment.origin
          CTLineDraw(segment.line, context)
        }
        if !segment.style.decorations.isEmpty {
          let next = position + 1 < fragments.count ? fragments[position + 1] : nil
          let continues =
            next.map {
              $0.lineTop == fragment.lineTop
                && segments[$0.segment].style.decorations.isSuperset(of: segment.style.decorations)
            } ?? false
          drawDecorations(segment, fragment: fragment, trimTrailing: !continues)
        }
        if fragment.isClipped { context.restoreGState() }
      }
    }
  }

  private func tokens(for fragment: TextFragment) -> (line: SceneIndex.CodeLine, spans: [TokenSpan])? {
    guard let line = index.codeLine(containing: fragment.range.lowerBound),
      let result = highlights[line.block], result.isHighlighted,
      result.codeDigest == index.codeDigests[line.block]
    else { return nil }
    let spans = result.tokens(line: line.line)
    return spans.isEmpty ? nil : (line, spans)
  }

  private func drawTokens(
    _ segment: ShapedSegment, fragment: TextFragment, line: SceneIndex.CodeLine, spans: [TokenSpan]
  ) {
    let base = segment.range.lowerBound - segment.lineStart - line.range.lowerBound
    func token(at stringIndex: Int) -> SyntaxToken? {
      let local = stringIndex + base
      var low = 0
      var high = spans.count
      while low < high {
        let mid = (low + high) / 2
        if spans[mid].range.upperBound <= local { low = mid + 1 } else { high = mid }
      }
      return low < spans.count && spans[low].range.contains(local) ? spans[low].token : nil
    }
    for run in CTLineGetGlyphRuns(segment.line) as? [CTRun] ?? [] {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      var indices = [CFIndex](repeating: 0, count: count)
      CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
      var start = 0
      var current = token(at: indices[0])
      for glyph in 1...count {
        let next = glyph < count ? token(at: indices[glyph]) : nil
        guard glyph == count || next != current else { continue }
        context.setFillColor(current.map { colors($0) } ?? colors(.code))
        context.textPosition = fragment.origin
        CTRunDraw(run, context, CFRange(location: start, length: glyph - start))
        start = glyph
        current = next
      }
    }
  }

  private func drawDecorations(_ segment: ShapedSegment, fragment: TextFragment, trimTrailing: Bool) {
    guard let run = (CTLineGetGlyphRuns(segment.line) as? [CTRun])?.first,
      let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String]
    else { return }
    let ctFont = font as! CTFont
    var minX = fragment.minX
    var maxX = fragment.maxX
    if trimTrailing, !fragment.isClipped {
      if segment.isRightToLeft { minX += segment.trailingWhitespace } else { maxX -= segment.trailingWhitespace }
    }
    guard maxX > minX else { return }
    let thickness = max(hairline, CTFontGetUnderlineThickness(ctFont).rounded())
    let baseline = fragment.origin.y
    context.setFillColor(colors(segment.style.color))
    let decorations = segment.style.decorations
    if decorations.contains(.underline) {
      let y = baseline - CTFontGetUnderlinePosition(ctFont)
      context.fill(CGRect(x: minX, y: y, width: maxX - minX, height: thickness))
    }
    if decorations.contains(.strikethrough) {
      let y = baseline - CTFontGetXHeight(ctFont) / 2 - thickness / 2
      context.fill(CGRect(x: minX, y: y, width: maxX - minX, height: thickness))
    }
    if decorations.contains(.dottedUnderline) {
      let y = baseline - CTFontGetUnderlinePosition(ctFont) + thickness / 2
      context.saveGState()
      context.setStrokeColor(colors(segment.style.color))
      context.setLineWidth(thickness)
      context.setLineDash(phase: 0, lengths: [thickness, thickness * 2])
      context.move(to: CGPoint(x: minX, y: y))
      context.addLine(to: CGPoint(x: maxX, y: y))
      context.strokePath()
      context.restoreGState()
    }
  }

  private func paintCopyButton() {
    var block = overlay.copyButton?.block
    switch overlay.focus {
    case .codeBlock(let id): block = block ?? id
    case .target(.copyCode(let id, _)): block = block ?? id
    default: break
    }
    guard let block, let rect = index.copyButtons[block], visible.intersects(rect) else { return }
    let copied = overlay.copyButton?.block == block && overlay.copyButton?.copied == true
    let label = TextLine(
      copied ? CopyButtonMetrics.copiedLabel : CopyButtonMetrics.copyLabel,
      font: CopyButtonMetrics.labelFont(typography))
    let iconSize = em(CopyButtonMetrics.iconScale)
    let gap = em(CopyButtonMetrics.gapScale)
    let radius = em(typography.cornerRadius)
    fill(rect, colors(\.inlineCodeBackground), radius: radius)
    stroke(rect, colors(\.border), width: hairline, radius: radius)
    let contentWidth = iconSize + gap + label.width
    let icon = CGRect(
      x: rect.midX - contentWidth / 2, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize)
    let accent = copied ? colors(\.alerts.tip) : colors(\.text)
    let glyphs = Glyphs(context: context, hairline: hairline)
    if copied { glyphs.check(in: icon, color: accent) } else { glyphs.copy(in: icon, color: accent) }
    context.setFillColor(accent)
    label.draw(in: context, at: CGPoint(x: icon.maxX + gap, y: rect.midY + (label.ascent - label.descent) / 2))
  }

  private func paintFocus() {
    guard let focus = overlay.focus else { return }
    var rects: [CGRect] = []
    switch focus {
    case .text(let range):
      rects = layout.rects(for: range).map(\.rect)
    case .codeBlock(let id):
      if let rect = index.codeBlockRects[id] { rects = [rect] }
    case .region(let id):
      if let rect = index.codeBlockRects[id] ?? layout.region(id)?.rect { rects = [rect] }
    case .target(let target):
      if case .copyCode(let id, _) = target, let rect = index.codeBlockRects[id] {
        rects = [rect]
      } else if let area = layout.targets.first(where: { $0.target == target }) {
        rects = [layout.displayRect(area.rect, region: area.region)]
      }
    }
    let width = hairline * 2
    for rect in rects where visible.intersects(rect) {
      stroke(
        rect.insetBy(dx: -width * 1.5, dy: -width * 1.5), colors(\.focusOutline), width: width,
        radius: em(typography.cornerRadius) + width)
    }
  }
}

struct TextLine {
  let line: CTLine
  let width: CGFloat
  let ascent: CGFloat
  let descent: CGFloat

  init(_ text: String, font: CTFont, truncateTo maximumWidth: CGFloat? = nil, truncation: CTLineTruncationType = .end) {
    let attributes: [NSAttributedString.Key: Any] = [
      .init(kCTFontAttributeName as String): font,
      .init(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    if let maximumWidth, CTLineGetTypographicBounds(line, nil, nil, nil) > maximumWidth {
      let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attributes))
      line = CTLineCreateTruncatedLine(line, max(Double(maximumWidth), 0), truncation, ellipsis) ?? ellipsis
    }
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    self.line = line
    self.ascent = ascent
    self.descent = descent
  }

  func draw(in context: CGContext, at origin: CGPoint) {
    context.textPosition = origin
    CTLineDraw(line, context)
  }
}
