import CoreGraphics
import Foundation
import MDViewerDocument

struct LayoutBuilder {
  var fragments: [TextFragment] = []
  var decorations: [Decoration] = []
  var labels: [PlacedLabel] = []
  var images: [ImageBox] = []
  var targets: [TargetArea] = []
  var regions: [ScrollRegion] = []
  var anchors: [(name: String, y: CGFloat)] = []
  var detailsTops: [(id: BlockID, y: CGFloat)] = []

  struct Mark {
    var fragments, decorations, labels, images, targets, anchors, detailsTops: Int
  }

  var mark: Mark {
    Mark(
      fragments: fragments.count, decorations: decorations.count, labels: labels.count, images: images.count,
      targets: targets.count, anchors: anchors.count, detailsTops: detailsTops.count)
  }

  mutating func shift(from start: Mark, to end: Mark, dy: CGFloat) {
    guard dy != 0 else { return }
    for index in start.fragments..<end.fragments {
      fragments[index].origin.y += dy
      fragments[index].lineTop += dy
      fragments[index].lineBottom += dy
    }
    for index in start.decorations..<end.decorations { decorations[index].rect.origin.y += dy }
    for index in start.labels..<end.labels { labels[index].origin.y += dy }
    for index in start.images..<end.images { images[index].rect.origin.y += dy }
    for index in start.targets..<end.targets { targets[index].rect.origin.y += dy }
    for index in start.anchors..<end.anchors { anchors[index].y += dy }
    for index in start.detailsTops..<end.detailsTops { detailsTops[index].y += dy }
  }

  mutating func assignRegion(_ region: BlockID, since start: Mark) {
    for index in start.fragments..<fragments.count where fragments[index].region == nil {
      fragments[index].region = region
    }
    for index in start.decorations..<decorations.count where decorations[index].region == nil {
      decorations[index].region = region
    }
    for index in start.labels..<labels.count where labels[index].region == nil { labels[index].region = region }
    for index in start.images..<images.count where images[index].region == nil { images[index].region = region }
    for index in start.targets..<targets.count where targets[index].region == nil { targets[index].region = region }
  }
}

struct LayoutContext {
  var alignment: TextAlignment?
  var isTight = false
}

struct LayoutEngine {
  let prepared: PreparedDocument
  let input: LayoutInput
  let typography: Typography
  var out = LayoutBuilder()

  init(prepared: PreparedDocument, input: LayoutInput) {
    self.prepared = prepared
    self.input = input
    typography = prepared.typography
  }

  func em(_ value: CGFloat) -> CGFloat { typography.pixels(em: value) }

  var hairline: CGFloat { max(1, typography.pixels(cssPoints: typography.hairline).rounded()) }

  mutating func run() -> CGFloat {
    let margin = em(typography.pageMarginSide)
    let width = max(input.width - margin * 2, em(4))
    var y = em(typography.pageMarginTop)
    var pending: CGFloat?
    sequence(prepared.nodes, x: margin, width: width, y: &y, context: LayoutContext(), pending: &pending)
    return y + em(typography.pageMarginBottom)
  }

  private mutating func sequence(
    _ nodes: [Node], x: CGFloat, width: CGFloat, y: inout CGFloat, context: LayoutContext, pending: inout CGFloat?
  ) {
    for node in nodes {
      if case .division(_, let alignment, let children) = node {
        division(children, alignment: alignment, x: x, width: width, y: &y, context: context, pending: &pending)
        continue
      }
      if let space = pending { y += max(space, marginTop(node)) }
      block(node, x: x, width: width, y: &y, context: context)
      pending = marginBottom(node, context: context)
    }
  }

  private mutating func division(
    _ children: [Node], alignment: TextAlignment, x: CGFloat, width: CGFloat, y: inout CGFloat,
    context: LayoutContext, pending: inout CGFloat?
  ) {
    var inner = context
    inner.alignment = alignment
    sequence(children, x: x, width: width, y: &y, context: inner, pending: &pending)
  }

  mutating func container(_ nodes: [Node], x: CGFloat, width: CGFloat, y: inout CGFloat, context: LayoutContext) {
    var pending: CGFloat?
    sequence(nodes, x: x, width: width, y: &y, context: context, pending: &pending)
  }

  private func marginTop(_ node: Node) -> CGFloat {
    switch node {
    case .heading: em(typography.headingSpacingTop)
    case .rule: em(typography.thematicBreakSpacing)
    case .footnote(_, _, _, let isFirst, _): isFirst ? em(typography.blockSpacing * 2) : 0
    default: 0
    }
  }

  private func marginBottom(_ node: Node, context: LayoutContext) -> CGFloat {
    switch node {
    case .paragraph(_, _, let isPlain): isPlain || context.isTight ? 0 : em(typography.blockSpacing)
    case .rule: em(typography.thematicBreakSpacing)
    case .list: context.isTight ? 0 : em(typography.blockSpacing)
    case .footnote: em(typography.listItemSpacing)
    default: em(typography.blockSpacing)
    }
  }

  private mutating func block(_ node: Node, x: CGFloat, width: CGFloat, y: inout CGFloat, context: LayoutContext) {
    switch node {
    case .heading(_, let level, let slug, let run):
      heading(level, slug: slug, run: run, x: x, width: width, y: &y, context: context)
    case .paragraph(_, let run, _):
      flow(run, x: x, width: width, y: &y, alignment: context.alignment)
    case .quote(_, let children):
      quote(children, x: x, width: width, y: &y, context: context)
    case .alert(_, let kind, let title, let children):
      alert(kind, title: title, children: children, x: x, width: width, y: &y, context: context)
    case .list(_, let list):
      self.list(list, x: x, width: width, y: &y, context: context)
    case .code(let id, let lines):
      code(id, lines: lines, x: x, width: width, y: &y)
    case .diagram(let id, let code):
      diagram(id, code: code, x: x, width: width, y: &y)
    case .table(let id, let table):
      self.table(id, table, x: x, width: width, y: &y, alignment: context.alignment)
    case .footnote(_, let label, let marker, let isFirst, let children):
      footnote(label, marker: marker, isFirst: isFirst, children: children, x: x, width: width, y: &y, context: context)
    case .details(let id, let summary, let children):
      details(id, summary: summary, children: children, x: x, width: width, y: &y, context: context)
    case .division(_, _, let children):
      container(children, x: x, width: width, y: &y, context: context)
    case .rule:
      rule(x: x, width: width, y: &y)
    case .frontMatter(_, let rows):
      frontMatter(rows, x: x, width: width, y: &y)
    }
  }

  private mutating func heading(
    _ level: Int, slug: String?, run: Run, x: CGFloat, width: CGFloat, y: inout CGFloat, context: LayoutContext
  ) {
    if let slug { out.anchors.append((slug, y)) }
    flow(run, x: x, width: width, y: &y, alignment: context.alignment)
    guard level <= 2 else { return }
    y += (typography.headingScale(level) * typography.headingRulePadding * typography.bodyPixelSize).rounded()
    out.decorations.append(
      Decoration(
        rect: CGRect(x: x, y: y, width: width, height: hairline), kind: .headingRule, region: nil, cornerRadius: 0))
    y += hairline
  }

  private mutating func quote(_ children: [Node], x: CGFloat, width: CGFloat, y: inout CGFloat, context: LayoutContext)
  {
    let top = y
    let bar = em(typography.barWidth)
    let inset = bar + em(typography.blockquotePadding)
    let mirrored = startsRightToLeft(children)
    container(children, x: mirrored ? x : x + inset, width: max(width - inset, em(1)), y: &y, context: context)
    out.decorations.append(
      Decoration(
        rect: CGRect(x: mirrored ? x + width - bar : x, y: top, width: bar, height: y - top), kind: .blockquoteBar,
        region: nil, cornerRadius: 0))
  }

  private mutating func footnote(
    _ label: String, marker: Int, isFirst: Bool, children: [Node], x: CGFloat, width: CGFloat, y: inout CGFloat,
    context: LayoutContext
  ) {
    if isFirst {
      out.decorations.append(
        Decoration(
          rect: CGRect(x: x, y: y, width: width, height: hairline), kind: .footnoteSeparator, region: nil,
          cornerRadius: 0))
      y += hairline + em(typography.blockSpacing)
    }
    out.anchors.append(("fn-\(label)", y))
    let indent = em(typography.footnoteIndent)
    let start = out.mark
    let top = y
    container(children, x: x + indent, width: max(width - indent, em(1)), y: &y, context: context)
    placeMarker(marker, contentX: x + indent, firstFragment: start.fragments, labelIndex: start.labels, top: top)
  }

  private mutating func rule(x: CGFloat, width: CGFloat, y: inout CGFloat) {
    let height = em(typography.thematicBreakHeight)
    out.decorations.append(
      Decoration(
        rect: CGRect(x: x, y: y, width: width, height: height), kind: .thematicBreak, region: nil, cornerRadius: 0))
    y += height
  }

  private mutating func alert(
    _ kind: AlertKind, title: Int, children: [Node], x: CGFloat, width: CGFloat, y: inout CGFloat,
    context: LayoutContext
  ) {
    let top = y
    let bar = em(typography.barWidth)
    let inset = bar + em(typography.alertPadding.width)
    let inner = max(width - inset - em(typography.alertPadding.width), em(1))
    let mirrored = startsRightToLeft(children)
    let innerX = mirrored ? x + width - inset - inner : x + inset
    y += em(typography.alertPadding.height)
    let rowHeight = em(typography.alertIconSize)
    let label = prepared.labels[title]
    let gap = em(typography.alertIconGap)
    let iconX = mirrored ? innerX + inner - rowHeight : innerX
    out.decorations.append(
      Decoration(
        rect: CGRect(x: iconX, y: y, width: rowHeight, height: rowHeight), kind: .alertIcon(kind), region: nil,
        cornerRadius: 0))
    out.labels.append(
      PlacedLabel(
        label: title,
        origin: CGPoint(
          x: mirrored ? iconX - gap - label.width : iconX + rowHeight + gap,
          y: y + (rowHeight - label.ascent - label.descent) / 2 + label.ascent), region: nil))
    y += rowHeight
    if !children.isEmpty {
      y += em(typography.alertTitleGap)
      container(children, x: innerX, width: inner, y: &y, context: context)
    }
    y += em(typography.alertPadding.height)
    out.decorations.append(
      Decoration(
        rect: CGRect(x: mirrored ? x + width - bar : x, y: top, width: bar, height: y - top), kind: .alertBar(kind),
        region: nil, cornerRadius: 0))
  }

  private mutating func list(_ list: ListNode, x: CGFloat, width: CGFloat, y: inout CGFloat, context: LayoutContext) {
    let indent = em(typography.listIndent)
    var inner = context
    inner.isTight = list.isTight
    for (index, item) in list.items.enumerated() {
      if index > 0 { y += em(list.isTight ? typography.listItemSpacing : typography.blockSpacing) }
      let top = y
      let mark = out.mark
      let start = mark.fragments
      let mirrored = startsRightToLeft(item.children)
      let itemWidth = max(width - indent, em(1))
      let itemX = mirrored ? x : x + indent
      container(item.children, x: itemX, width: itemWidth, y: &y, context: inner)
      if y == top { y += em(typography.bodyLineHeight) }
      if let marker = item.marker {
        placeMarker(
          marker, contentX: mirrored ? itemX + itemWidth : itemX, mirrored: mirrored, firstFragment: start,
          labelIndex: mark.labels, top: top)
      }
      if let task = item.task {
        let line = firstLine(from: start, top: top)
        let size = em(typography.taskBoxSize)
        let offset = em(typography.taskBoxOffset)
        let rect = CGRect(
          x: mirrored ? itemX + itemWidth + offset - size : itemX - offset, y: (line.top + line.bottom - size) / 2,
          width: size, height: size)
        out.decorations.append(
          Decoration(rect: rect, kind: .taskBox(checked: task == .checked), region: nil, cornerRadius: size / 5))
        out.targets.append(TargetArea(rect: rect, target: .task(item.id, checked: task == .checked), region: nil))
      }
    }
  }

  func startsRightToLeft(_ nodes: [Node]) -> Bool {
    var pending = Array(nodes.reversed())
    while let node = pending.popLast() {
      switch node {
      case .heading(_, _, _, let run), .paragraph(_, let run, _):
        if run.hasStrongDirection { return run.isRightToLeft }
      case .quote(_, let children), .alert(_, _, _, let children), .footnote(_, _, _, _, let children),
        .division(_, _, let children):
        pending += children.reversed()
      case .list(_, let list):
        pending += list.items.flatMap(\.children).reversed()
      case .details(_, let summary, let children):
        if summary.hasStrongDirection { return summary.isRightToLeft }
        pending += children.reversed()
      case .code, .diagram, .table, .rule, .frontMatter:
        continue
      }
    }
    return false
  }

  private func firstLine(from start: Int, top: CGFloat) -> (top: CGFloat, bottom: CGFloat, baseline: CGFloat) {
    if start < out.fragments.count {
      let fragment = out.fragments[start]
      let segment = prepared.segments[fragment.segment]
      return (fragment.lineTop, fragment.lineBottom, fragment.origin.y - segment.baselineShift)
    }
    let height = em(typography.bodyLineHeight)
    return (top, top + height, top + height * 0.75)
  }

  private mutating func placeMarker(
    _ marker: Int, contentX: CGFloat, mirrored: Bool = false, firstFragment: Int, labelIndex: Int, top: CGFloat
  ) {
    let label = prepared.labels[marker]
    let line = firstLine(from: firstFragment, top: top)
    out.labels.insert(
      PlacedLabel(
        label: marker,
        origin: CGPoint(
          x: mirrored ? contentX + em(typography.listMarkerGap) : contentX - em(typography.listMarkerGap) - label.width,
          y: line.baseline), region: nil),
      at: labelIndex)
  }

  private mutating func code(_ id: BlockID, lines: [Run], x: CGFloat, width: CGFloat, y: inout CGFloat) {
    let padding = em(typography.codePadding)
    let top = y
    let start = out.mark
    var widest: CGFloat = 0
    y += padding
    for line in lines {
      let baseline = y + line.strutAbove
      var lineX = x + padding
      for atom in line.atoms {
        guard case .segment(let index) = atom else { continue }
        let segment = prepared.segments[index]
        out.fragments.append(
          TextFragment(
            segment: index, range: segment.range, origin: CGPoint(x: lineX + segment.drawOffset, y: baseline),
            minX: lineX,
            maxX: lineX + segment.width, lineTop: y, lineBottom: baseline + line.strutBelow, region: nil,
            isClipped: false))
        lineX += segment.width
      }
      widest = max(widest, lineX - x - padding)
      y = baseline + line.strutBelow
    }
    y += padding
    let box = CGRect(x: x, y: top, width: width, height: y - top)
    let contentWidth = widest + padding * 2
    if contentWidth > width {
      out.assignRegion(id, since: start)
      out.regions.append(
        ScrollRegion(
          id: id, rect: box, contentWidth: contentWidth, offset: clampedOffset(id, contentWidth, width),
          kind: .codeBlock(language: prepared.codeBlocks[id]?.language)))
    }
    out.decorations.insert(
      Decoration(rect: box, kind: .codeBlockBackground, region: nil, cornerRadius: em(typography.cornerRadius)),
      at: start.decorations)
    let size = em(typography.copyButtonSize)
    let inset = em(typography.copyButtonInset)
    let button = CGRect(x: box.maxX - inset - size, y: top + inset, width: size, height: size)
    out.decorations.append(
      Decoration(rect: button, kind: .copyButton, region: nil, cornerRadius: em(typography.cornerRadius)))
    out.targets.append(
      TargetArea(rect: button, target: .copyCode(id, language: prepared.codeBlocks[id]?.language), region: nil))
  }

  func lineWidth(_ line: Run) -> CGFloat {
    var width: CGFloat = 0
    for atom in line.atoms {
      if case .segment(let index) = atom { width += prepared.segments[index].width }
    }
    return width
  }

  private func clampedOffset(_ id: BlockID, _ contentWidth: CGFloat, _ width: CGFloat) -> CGFloat {
    min(max(input.scrollOffsets[id] ?? 0, 0), max(0, contentWidth - width))
  }

  private mutating func diagram(_ id: BlockID, code: String, x: CGFloat, width: CGFloat, y: inout CGFloat) {
    let intrinsic = input.diagramSize(code)
    var size =
      intrinsic.map {
        CGSize(width: typography.pixels(cssPoints: $0.width), height: typography.pixels(cssPoints: $0.height))
      }
      ?? CGSize(width: width, height: em(typography.diagramPlaceholderHeight))
    if size.width > width, size.width > 0 {
      size = CGSize(width: width, height: size.height * width / size.width)
    }
    let rect = CGRect(x: x + (width - size.width) / 2, y: y, width: size.width, height: size.height)
    out.images.append(
      ImageBox(
        rect: rect, content: .diagram(code: code), alt: "", link: nil, hasIntrinsicSize: intrinsic != nil,
        region: nil, block: id))
    y += size.height
  }

  private mutating func details(
    _ id: BlockID, summary: Run, children: [Node], x: CGFloat, width: CGFloat, y: inout CGFloat,
    context: LayoutContext
  ) {
    let top = y
    let expanded = input.expandedDetails.contains(id)
    out.detailsTops.append((id, top))
    let markerWidth = em(typography.detailsMarkerWidth)
    let start = out.fragments.count
    flow(summary, x: x + markerWidth, width: max(width - markerWidth, em(1)), y: &y, alignment: nil)
    let line = firstLine(from: start, top: top)
    let size = em(typography.detailsMarkerSize)
    out.decorations.append(
      Decoration(
        rect: CGRect(
          x: x + (markerWidth - size) / 2 - size / 4, y: (line.top + line.bottom - size) / 2, width: size, height: size),
        kind: .disclosure(expanded: expanded), region: nil, cornerRadius: 0))
    out.targets.append(
      TargetArea(rect: CGRect(x: x, y: top, width: width, height: y - top), target: .detailsToggle(id), region: nil))
    guard expanded, !children.isEmpty else { return }
    container(children, x: x, width: width, y: &y, context: context)
  }

  private mutating func frontMatter(_ rows: [(key: Run, value: Run)], x: CGFloat, width: CGFloat, y: inout CGFloat) {
    let top = y
    let start = out.mark
    let bar = em(typography.frontMatterBarWidth)
    let padX = em(typography.frontMatterPadding.width)
    let padY = em(typography.frontMatterPadding.height)
    let gap = em(typography.frontMatterColumnGap)
    let chrome = bar + padX * 2 + gap
    let available = max(width - chrome, em(2))
    let keyNatural = rows.map(\.key.maxWidth).max() ?? 0
    let keyWidth = min(keyNatural, available / 2)
    let valueNatural = rows.map(\.value.maxWidth).max() ?? 0
    let valueWidth = max(min(valueNatural, available - keyWidth), em(1))
    let boxWidth = min(width, chrome + keyWidth + valueWidth)
    y += padY
    for row in rows {
      var keyY = y
      var valueY = y
      flow(row.key, x: x + bar + padX, width: max(keyWidth, em(1)), y: &keyY, alignment: nil)
      flow(row.value, x: x + bar + padX + keyWidth + gap, width: valueWidth, y: &valueY, alignment: nil)
      y = max(keyY, valueY)
    }
    y += padY
    let box = CGRect(x: x, y: top, width: boxWidth, height: y - top)
    out.decorations.insert(
      Decoration(rect: box, kind: .frontMatterBackground, region: nil, cornerRadius: em(typography.cornerRadius)),
      at: start.decorations)
    out.decorations.append(
      Decoration(
        rect: CGRect(x: x, y: top, width: bar, height: y - top), kind: .frontMatterBar, region: nil, cornerRadius: 0))
  }
}
