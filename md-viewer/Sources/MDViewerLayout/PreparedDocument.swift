import CoreText
import Foundation
import MDViewerDocument

public struct LinkSpan: Hashable, Sendable {
  public var range: Range<Int>
  public var href: String
}

struct SourceSpan {
  var range: Range<Int>
  var source: SourceRange
}

public struct CodeBlockInfo: Hashable, Sendable {
  public var language: String?
  public var code: String
  public var lineRanges: [Range<Int>]
  public var isDiagram: Bool
}

public final class PreparedDocument: @unchecked Sendable {
  public let document: Document
  public let source: String
  public let typography: Typography
  public let text: NSString
  public let segments: [ShapedSegment]
  public let labels: [ShapedLabel]
  public let units: [TextUnit]
  public let links: [LinkSpan]
  public let initiallyExpandedDetails: Set<BlockID>
  public let codeBlocks: [BlockID: CodeBlockInfo]
  let nodes: [Node]
  let images: [ImageAtom]
  let detailsBodies: [BlockID: Range<Int>]
  let anchorAncestors: [String: [BlockID]]
  let sourceSpans: [SourceSpan]
  let sourceLines: [String]

  public convenience init(markdown: String, typography: Typography = Typography()) {
    self.init(document: Document.parse(markdown), source: markdown, typography: typography)
  }

  public init(document: Document, source: String, typography: Typography) {
    let preparer = Preparer(typography: typography, source: source)
    nodes = preparer.prepare(document)
    self.document = document
    self.source = source
    self.typography = typography
    text = preparer.text.copy() as? NSString ?? ""
    segments = preparer.segments
    labels = preparer.labels
    units = preparer.units
    links = preparer.links
    initiallyExpandedDetails = preparer.initiallyExpanded
    codeBlocks = preparer.codeBlocks
    images = preparer.images
    detailsBodies = preparer.detailsBodies
    anchorAncestors = preparer.anchorAncestors
    sourceSpans = preparer.sourceSpans
    sourceLines = Self.lines(source)
  }

  public var anchorNames: Set<String> { Set(anchorAncestors.keys) }

  static func lines(_ source: String) -> [String] {
    var lines: [String] = []
    var current = String.UnicodeScalarView()
    var previousWasReturn = false
    for scalar in source.unicodeScalars {
      if scalar == "\n", previousWasReturn {
        previousWasReturn = false
        continue
      }
      previousWasReturn = scalar == "\r"
      if scalar == "\n" || scalar == "\r" {
        lines.append(String(current))
        current = String.UnicodeScalarView()
      } else {
        current.append(scalar)
      }
    }
    lines.append(String(current))
    return lines
  }
}

private struct SpanStyle: Hashable {
  var size: CGFloat = 1
  var weight: FontWeight = .regular
  var italic = false
  var monospaced = false
  var color: TextColorRole = .text
  var decorations: TextDecorations = []
  var box: InlineBoxKind?
  var group: Int?
  var link: String?
  var shift: CGFloat = 0
  var affectsLineHeight = true
}

private struct Context {
  var style = SpanStyle()
  var lineHeight: CGFloat
  var isTight = false
  var listDepth = 0
  var details: [BlockID] = []
  var unitKind: TextUnitKind = .inline
  var unitSource: SourceRange?
}

private enum RunItem {
  case text(String, SpanStyle, SourceRange)
  case hardBreak(SpanStyle, SourceRange)
  case image(Image, link: String?)
  case anchor(String)
}

private enum Direction {
  case leftToRight, rightToLeft

  init?(strong scalar: Unicode.Scalar) {
    guard scalar.properties.isAlphabetic else { return nil }
    switch scalar.value {
    case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
      self = .rightToLeft
    default:
      self = .leftToRight
    }
  }
}

private final class Preparer {
  static let maximumSegmentLength = 256

  let typography: Typography
  let source: String
  let fonts: FontCache
  let text = NSMutableString()
  var segments: [ShapedSegment] = []
  var labels: [ShapedLabel] = []
  var units: [TextUnit] = []
  var links: [LinkSpan] = []
  var images: [ImageAtom] = []
  var initiallyExpanded: Set<BlockID> = []
  var detailsBodies: [BlockID: Range<Int>] = [:]
  var anchorAncestors: [String: [BlockID]] = [:]
  var sourceSpans: [SourceSpan] = []
  var codeBlocks: [BlockID: CodeBlockInfo] = [:]
  private var nextID = 0
  private var nextGroup = 0
  private var pendingSeparator: String?
  private var currentBlock = BlockID(0)
  private var currentDetails: [BlockID] = []
  private var seenFootnote = false
  private var trailingItems: [RunItem] = []

  init(typography: Typography, source: String) {
    self.typography = typography
    self.source = source
    fonts = FontCache(tabWidth: typography.tabWidth)
  }

  private func makeID() -> BlockID {
    defer { nextID += 1 }
    return BlockID(nextID)
  }

  func prepare(_ document: Document) -> [Node] {
    let base = Context(lineHeight: typography.bodyLineHeight)
    var nodes: [Node] = []
    if !document.frontMatter.isEmpty {
      nodes.append(frontMatter(document.frontMatter, context: base))
    }
    return nodes + blocks(document.blocks, context: base)
  }

  private func frontMatter(_ entries: [FrontMatterEntry], context: Context) -> Node {
    let id = makeID()
    currentBlock = id
    let lastLine = max(FrontMatter.split(source).bodyLineOffset, 1)
    let range = SourceRange(start: SourcePosition(line: 1, column: 1), end: SourcePosition(line: lastLine, column: 1))
    var keyStyle = SpanStyle(size: typography.frontMatterScale, weight: typography.strongWeight)
    keyStyle.color = .muted
    let valueStyle = SpanStyle(size: typography.frontMatterScale)
    var inner = context
    inner.lineHeight = typography.frontMatterLineHeight
    var rows: [(key: Run, value: Run)] = []
    for (index, entry) in entries.enumerated() {
      if index > 0 { pendingSeparator = "\n" }
      let unit = beginUnit(id, kind: .frontMatter, source: range)
      let key = run([.text(entry.key, keyStyle, range)], base: keyStyle, context: inner, wrap: true)
      text.append(": ")
      var items: [RunItem] = []
      for (lineIndex, line) in entry.value.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        if lineIndex > 0 { items.append(.hardBreak(valueStyle, range)) }
        items.append(.text(String(line), valueStyle, range))
      }
      let value = run(items, base: valueStyle, context: inner, wrap: true)
      endUnit(unit)
      rows.append((key, value))
    }
    return .frontMatter(id, rows)
  }

  private func blocks(_ blocks: [Block], context: Context) -> [Node] {
    var nodes: [Node] = []
    for (index, block) in blocks.enumerated() {
      if index > 0 { pendingSeparator = context.isTight ? "\n" : "\n\n" }
      nodes.append(contentsOf: node(block, context: context))
    }
    return nodes
  }

  private func node(_ block: Block, context: Context) -> [Node] {
    let id = makeID()
    currentBlock = id
    switch block.kind {
    case .heading(let heading):
      var inner = context
      inner.style.size = typography.headingScale(heading.level)
      inner.style.weight = typography.headingWeight(heading.level)
      inner.style.color = heading.level == 6 ? .muted : .heading
      inner.lineHeight = typography.headingLineHeight
      if let slug = heading.slug { registerAnchor(slug) }
      let content = inlineRun(
        heading.content, block: id, kind: context.unitKind, source: context.unitSource ?? block.range, context: inner)
      return [.heading(id, level: heading.level, slug: heading.slug, content)]
    case .paragraph(let inlines), .plain(let inlines):
      let content = inlineRun(
        inlines, block: id, kind: context.unitKind, source: context.unitSource ?? block.range, context: context)
      if case .plain = block.kind { return [.paragraph(id, content, isPlain: true)] }
      return [.paragraph(id, content, isPlain: false)]
    case .blockQuote(let children):
      var inner = context
      inner.style.color = .muted
      return [.quote(id, blocks(children, context: inner))]
    case .alert(let alert):
      var titleStyle = SpanStyle(weight: typography.alertTitleWeight)
      titleStyle.color = .alertTitle(alert.kind)
      let title = label(alert.kind.title, style: titleStyle, role: .alertTitle(alert.kind))
      var inner = context
      inner.style.color = .text
      return [.alert(id, alert.kind, title: title, blocks(alert.blocks, context: inner))]
    case .list(let list):
      return [.list(id, listNode(list, context: context))]
    case .codeBlock(let code):
      return [codeNode(code, id: id, source: context.unitSource ?? block.range, context: context)]
    case .table(let table):
      var inner = context
      inner.unitSource = context.unitSource ?? block.range
      return [.table(id, tableNode(table, context: inner))]
    case .footnoteDefinition(let footnote):
      registerAnchor("fn-\(footnote.label)")
      var inner = context
      inner.style.size = typography.footnoteScale
      inner.style.color = .muted
      let marker = label("\(footnote.number).", style: inner.style, role: .listMarker)
      let isFirst = !seenFootnote
      seenFootnote = true
      let children = footnoteBlocks(footnote, range: block.range, context: inner)
      return [.footnote(id, label: footnote.label, marker: marker, isFirst: isFirst, children)]
    case .details(let details):
      if details.isOpen { initiallyExpanded.insert(id) }
      let summary = inlineRun(
        details.summary, block: id, kind: context.unitKind, source: context.unitSource ?? block.range,
        context: context)
      let bodyStart = text.length
      var inner = context
      inner.details.append(id)
      currentDetails = inner.details
      let children = blocks(details.blocks, context: inner)
      currentDetails = context.details
      detailsBodies[id] = bodyStart..<text.length
      return [.details(id, summary: summary, children)]
    case .division(let division):
      return [.division(id, division.alignment, blocks(division.blocks, context: context))]
    case .thematicBreak:
      return [.rule(id)]
    }
  }

  private func footnoteBlocks(_ footnote: FootnoteDefinition, range: SourceRange, context: Context) -> [Node] {
    let end = SourcePosition(line: range.end.line, column: range.end.column + 1)
    let empty = SourceRange(start: end, end: range.end)
    var style = context.style
    style.link = "#fnref-\(footnote.label)"
    style.color = .link
    let backlink = RunItem.text("\u{21A9}", style, empty)
    var content = footnote.blocks
    if let last = content.last, case .paragraph = last.kind {
      content.removeLast()
      var nodes = blocks(content, context: context)
      if !content.isEmpty { pendingSeparator = "\n\n" }
      trailingItems = [.text(" ", context.style, empty), backlink]
      nodes += node(last, context: context)
      return nodes
    }
    var nodes = blocks(content, context: context)
    let id = makeID()
    currentBlock = id
    if !content.isEmpty { pendingSeparator = "\n\n" }
    let unit = beginUnit(id, kind: context.unitKind, source: empty)
    let backlinkRun = run([backlink], base: context.style, context: context, wrap: true)
    endUnit(unit)
    nodes.append(.paragraph(id, backlinkRun, isPlain: false))
    return nodes
  }

  private func listNode(_ list: List, context: Context) -> ListNode {
    var inner = context
    inner.isTight = list.isTight
    inner.listDepth += 1
    var items: [ItemNode] = []
    for (index, item) in list.items.enumerated() {
      if index > 0 { pendingSeparator = list.isTight ? "\n" : "\n\n" }
      let id = makeID()
      var marker: Int?
      if item.task == nil {
        marker = label(
          markerText(list.kind, index: index, depth: context.listDepth), style: context.style, role: .listMarker)
      }
      items.append(ItemNode(id: id, marker: marker, task: item.task, children: blocks(item.blocks, context: inner)))
    }
    return ListNode(isTight: list.isTight, items: items)
  }

  private func markerText(_ kind: List.Kind, index: Int, depth: Int) -> String {
    switch kind {
    case .bullet:
      return ["\u{2022}", "\u{25E6}", "\u{25AA}"][min(depth, 2)]
    case .ordered(let start):
      let number = start + index
      switch depth {
      case 0: return "\(number)."
      case 1: return "\(romanNumeral(number))."
      default: return "\(alphabetic(number))."
      }
    }
  }

  private func codeNode(_ code: CodeBlock, id: BlockID, source: SourceRange, context: Context) -> Node {
    if code.language?.lowercased() == "mermaid" {
      endUnit(beginUnit(id, kind: .diagram, source: source))
      codeBlocks[id] = CodeBlockInfo(language: "mermaid", code: code.code, lineRanges: [], isDiagram: true)
      return .diagram(id, code: code.code)
    }
    var lines = code.code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    var style = SpanStyle(size: typography.codeScale, monospaced: true)
    style.color = .code
    var inner = context
    inner.lineHeight = typography.codeLineHeight
    var runs: [Run] = []
    var lineRanges: [Range<Int>] = []
    for (index, line) in lines.enumerated() {
      if index > 0 { pendingSeparator = "\n" }
      let unit = beginUnit(id, kind: .codeLine, source: source)
      runs.append(run([.text(line, style, source)], base: style, context: inner, wrap: false))
      endUnit(unit)
      lineRanges.append(units[unit].range)
    }
    codeBlocks[id] = CodeBlockInfo(language: code.language, code: code.code, lineRanges: lineRanges, isDiagram: false)
    return .code(id, lines: runs)
  }

  private func tableNode(_ table: Table, context: Context) -> TableNode {
    let rows = (table.header.map { [$0] } ?? []) + table.rows
    var nodes: [[CellNode]] = []
    for (rowIndex, row) in rows.enumerated() {
      var cells: [CellNode] = []
      for (column, cell) in row.cells.enumerated() {
        if column > 0 {
          pendingSeparator = "\t"
        } else if rowIndex > 0 {
          pendingSeparator = "\n"
        }
        let id = makeID()
        var inner = context
        inner.isTight = true
        inner.unitKind = .tableCell
        if cell.isHeader { inner.style.weight = typography.strongWeight }
        let children: [Node]
        if cell.content.isEmpty {
          endUnit(beginUnit(id, kind: .tableCell, source: context.unitSource ?? cell.range))
          children = []
        } else {
          children = blocks(cell.content, context: inner)
        }
        cells.append(
          CellNode(
            id: id, children: children, alignment: cell.alignment,
            isHeader: cell.isHeader || (rowIndex == 0 && table.header != nil), columnSpan: cell.columnSpan,
            rowSpan: cell.rowSpan))
      }
      nodes.append(cells)
    }
    return TableNode(rows: nodes, headerRows: table.header == nil ? 0 : 1)
  }

  private func registerAnchor(_ name: String) {
    guard !name.isEmpty, anchorAncestors[name] == nil else { return }
    anchorAncestors[name] = currentDetails
  }

  private func beginUnit(_ block: BlockID, kind: TextUnitKind, source: SourceRange) -> Int {
    if text.length > 0 { text.append(pendingSeparator ?? "\n\n") }
    pendingSeparator = nil
    units.append(TextUnit(range: text.length..<text.length, block: block, kind: kind, source: source))
    return units.count - 1
  }

  private func endUnit(_ index: Int) {
    units[index].range = units[index].range.lowerBound..<text.length
  }

  private func inlineRun(
    _ inlines: [Inline], block: BlockID, kind: TextUnitKind, source: SourceRange, context: Context
  ) -> Run {
    let unit = beginUnit(block, kind: kind, source: source)
    var items: [RunItem] = []
    collect(inlines, style: context.style, into: &items)
    items += trailingItems
    trailingItems = []
    let result = run(items, base: context.style, context: context, wrap: true)
    endUnit(unit)
    return result
  }

  private func collect(_ inlines: [Inline], style: SpanStyle, into items: inout [RunItem]) {
    for inline in inlines {
      var inner = style
      switch inline.kind {
      case .text(let value):
        items.append(.text(value, style, inline.range))
      case .softBreak:
        items.append(.text(" ", style, inline.range))
      case .hardBreak:
        items.append(.hardBreak(style, inline.range))
      case .code(let value):
        inner.monospaced = true
        inner.size = style.size * typography.codeScale
        inner.box = .code
        inner.group = makeGroup()
        if inner.link == nil { inner.color = .inlineCode }
        items.append(.text(value, inner, inline.range))
      case .emphasis(let children):
        inner.italic = true
        collect(children, style: inner, into: &items)
      case .strong(let children):
        inner.weight = typography.strongWeight
        collect(children, style: inner, into: &items)
      case .strikethrough(let children):
        inner.decorations.insert(.strikethrough)
        collect(children, style: inner, into: &items)
      case .keyboard(let children):
        inner.monospaced = true
        inner.size = style.size * typography.keyboardScale
        inner.box = .keyboard
        inner.group = makeGroup()
        inner.affectsLineHeight = false
        collect(children, style: inner, into: &items)
      case .subscript(let children):
        inner.size = style.size * typography.scriptScale
        inner.shift = 0.25
        inner.affectsLineHeight = false
        collect(children, style: inner, into: &items)
      case .superscript(let children):
        inner.size = style.size * typography.scriptScale
        inner.shift = -0.5
        inner.affectsLineHeight = false
        collect(children, style: inner, into: &items)
      case .inserted(let children):
        inner.decorations.insert(.underline)
        collect(children, style: inner, into: &items)
      case .marked(let children):
        inner.box = .mark
        inner.group = makeGroup()
        collect(children, style: inner, into: &items)
      case .small(let children):
        inner.size = style.size * typography.smallScale
        collect(children, style: inner, into: &items)
      case .abbreviation(_, let children):
        inner.decorations.insert(.dottedUnderline)
        collect(children, style: inner, into: &items)
      case .link(let link):
        inner.link = link.destination
        inner.color = .link
        collect(link.content, style: inner, into: &items)
      case .image(let image):
        items.append(.image(image, link: style.link))
      case .footnoteReference(let label, let number):
        let name = "fnref-\(label)"
        registerAnchor(name)
        items.append(.anchor(name))
        inner.link = "#fn-\(label)"
        inner.color = .link
        inner.size = style.size * typography.scriptScale
        inner.shift = -0.5
        inner.affectsLineHeight = false
        items.append(.text("\(number)", inner, inline.range))
      case .anchor(let name):
        registerAnchor(name)
        items.append(.anchor(name))
      }
    }
  }

  private func makeGroup() -> Int {
    defer { nextGroup += 1 }
    return nextGroup
  }

  private struct Piece {
    var range: Range<Int>
    var style: SpanStyle
  }

  private enum Entry {
    case piece(Piece)
    case hardBreak
    case image(Int)
    case anchor(String)
  }

  private func run(_ items: [RunItem], base: SpanStyle, context: Context, wrap: Bool) -> Run {
    let globalStart = text.length
    let local = NSMutableString()
    let attributed = NSMutableAttributedString()
    var entries: [Entry] = []
    for item in items {
      switch item {
      case .text(let value, let style, let source):
        guard !value.isEmpty else { continue }
        let start = local.length
        local.append(value)
        attributed.append(NSAttributedString(string: value, attributes: fonts.metrics(fontKey(style)).attributes))
        let range = start..<local.length
        if case .piece(let last)? = entries.last, last.style == style, last.range.upperBound == start {
          entries[entries.count - 1] = .piece(Piece(range: last.range.lowerBound..<range.upperBound, style: style))
        } else {
          entries.append(.piece(Piece(range: range, style: style)))
        }
        sourceSpans.append(
          SourceSpan(range: (globalStart + range.lowerBound)..<(globalStart + range.upperBound), source: source))
        if let link = style.link {
          let global = (globalStart + range.lowerBound)..<(globalStart + range.upperBound)
          if let last = links.last, last.href == link, last.range.upperBound == global.lowerBound {
            links[links.count - 1].range = last.range.lowerBound..<global.upperBound
          } else {
            links.append(LinkSpan(range: global, href: link))
          }
        }
      case .hardBreak(let style, let source):
        let start = local.length
        local.append("\n")
        attributed.append(NSAttributedString(string: "\n", attributes: fonts.metrics(fontKey(style)).attributes))
        sourceSpans.append(SourceSpan(range: (globalStart + start)..<(globalStart + start + 1), source: source))
        entries.append(.hardBreak)
      case .image(let image, let link):
        images.append(ImageAtom(image: image, link: link, block: currentBlock))
        entries.append(.image(images.count - 1))
      case .anchor(let name):
        entries.append(.anchor(name))
      }
    }
    text.append(local as String)
    let breaks = wrap ? breakOpportunities(local) : []
    var cutIndex = 0
    let direction = wrap ? baseDirection(local) : nil
    let isRightToLeft = direction == .rightToLeft
    if isRightToLeft || !wrap {
      let metrics = fonts.metrics(fontKey(base))
      attributed.addAttribute(
        .init(kCTParagraphStyleAttributeName as String),
        value: isRightToLeft ? metrics.rightToLeftParagraph : metrics.leftToRightParagraph,
        range: NSRange(location: 0, length: attributed.length))
    }
    let typesetter = local.length > 0 ? CTTypesetterCreateWithAttributedString(attributed) : nil

    struct Spec {
      var range: Range<Int>
      var style: SpanStyle
      var breakAfter: Bool
    }
    var specs: [Spec] = []
    var atomsPlan: [Int?] = []
    var atoms: [Atom] = []
    for entry in entries {
      switch entry {
      case .piece(let piece):
        var start = piece.range.lowerBound
        while cutIndex < breaks.count && breaks[cutIndex] <= start { cutIndex += 1 }
        while start < piece.range.upperBound {
          let cut = cutIndex < breaks.count ? min(breaks[cutIndex], piece.range.upperBound) : piece.range.upperBound
          let breakAfter = cutIndex < breaks.count && breaks[cutIndex] == cut
          var chunkStart = start
          while cut - chunkStart > Self.maximumSegmentLength {
            var chunkEnd = chunkStart
            while chunkEnd - chunkStart < Self.maximumSegmentLength {
              let composed = local.rangeOfComposedCharacterSequence(at: chunkEnd)
              let next = min(composed.location + composed.length, cut)
              if next - chunkStart > Self.maximumSegmentLength, chunkEnd > chunkStart { break }
              chunkEnd = next
            }
            specs.append(Spec(range: chunkStart..<chunkEnd, style: piece.style, breakAfter: false))
            atomsPlan.append(specs.count - 1)
            chunkStart = chunkEnd
          }
          specs.append(Spec(range: chunkStart..<cut, style: piece.style, breakAfter: breakAfter))
          atomsPlan.append(specs.count - 1)
          if breakAfter { cutIndex += 1 }
          start = cut
        }
      case .hardBreak:
        atomsPlan.append(nil)
        atoms.append(.hardBreak)
      case .image(let index):
        atomsPlan.append(nil)
        atoms.append(.image(index))
      case .anchor(let name):
        atomsPlan.append(nil)
        atoms.append(.anchor(name))
      }
    }
    if specs.isEmpty && !wrap {
      specs.append(Spec(range: 0..<0, style: base, breakAfter: true))
      atomsPlan.append(0)
    }

    var groupFirst: [Int: Int] = [:]
    var groupLast: [Int: Int] = [:]
    for (index, spec) in specs.enumerated() {
      guard let group = spec.style.group else { continue }
      if groupFirst[group] == nil { groupFirst[group] = index }
      groupLast[group] = index
    }

    let levels = bidiLevels(specs.map(\.range), in: local, isRightToLeft: isRightToLeft)
    let firstSegment = segments.count
    for (index, spec) in specs.enumerated() {
      segments.append(
        shape(
          spec.range, globalStart: globalStart, style: spec.style, typesetter: typesetter, context: context,
          breakAfter: spec.breakAfter, isGroupStart: spec.style.group.map { groupFirst[$0] == index } ?? false,
          isGroupEnd: spec.style.group.map { groupLast[$0] == index } ?? false, bidiLevel: levels[index],
          inRightToLeftParagraph: isRightToLeft))
    }

    var merged: [Atom] = []
    var otherIndex = 0
    for plan in atomsPlan {
      if let spec = plan {
        merged.append(.segment(firstSegment + spec))
      } else {
        merged.append(atoms[otherIndex])
        otherIndex += 1
      }
    }
    var result = finishRun(merged, base: base, context: context, isRightToLeft: isRightToLeft)
    result.hasStrongDirection = direction != nil
    return result
  }

  private func baseDirection(_ string: NSString) -> Direction? {
    for scalar in (string as String).unicodeScalars {
      if let direction = Direction(strong: scalar) { return direction }
    }
    return nil
  }

  private func bidiLevels(_ ranges: [Range<Int>], in string: NSString, isRightToLeft: Bool) -> [Int] {
    let directions = ranges.map { range -> Direction? in
      let piece = string.substring(with: NSRange(location: range.lowerBound, length: range.count))
      for scalar in piece.unicodeScalars {
        if let direction = Direction(strong: scalar) ?? (scalar.properties.numericType != nil ? .leftToRight : nil) {
          return direction
        }
      }
      return nil
    }
    let base: Direction = isRightToLeft ? .rightToLeft : .leftToRight
    var resolved = [Direction](repeating: base, count: ranges.count)
    var previous: Direction?
    for index in ranges.indices {
      if let direction = directions[index] {
        resolved[index] = direction
        previous = direction
        continue
      }
      let next = directions[(index + 1)...].lazy.compactMap { $0 }.first
      resolved[index] = previous != nil && previous == next ? previous ?? base : base
    }
    return resolved.map { direction in
      switch (base, direction) {
      case (.leftToRight, .leftToRight): 0
      case (.leftToRight, .rightToLeft): 1
      case (.rightToLeft, .rightToLeft): 1
      case (.rightToLeft, .leftToRight): 2
      }
    }
  }

  private func breakOpportunities(_ string: NSString) -> [Int] {
    guard string.length > 0 else { return [] }
    var result: [Int] = []
    let tokenizer = CFStringTokenizerCreate(
      nil, string, CFRange(location: 0, length: string.length), kCFStringTokenizerUnitLineBreak, nil)
    while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
      let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
      result.append(range.location + range.length)
    }
    return result
  }

  private func fontKey(_ style: SpanStyle) -> FontKey {
    FontKey(
      size: (style.size * typography.bodyPixelSize * 4).rounded() / 4, weight: style.weight, italic: style.italic,
      monospaced: style.monospaced)
  }

  private func shape(
    _ range: Range<Int>, globalStart: Int, style: SpanStyle, typesetter: CTTypesetter?, context: Context,
    breakAfter: Bool, isGroupStart: Bool, isGroupEnd: Bool, bidiLevel: Int, inRightToLeftParagraph: Bool
  ) -> ShapedSegment {
    let metrics = fonts.metrics(fontKey(style))
    let line: CTLine
    if let typesetter, !range.isEmpty {
      line = CTTypesetterCreateLine(typesetter, CFRange(location: range.lowerBound, length: range.count))
    } else {
      line = CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: metrics.attributes))
    }
    var lineAscent: CGFloat = 0
    var lineDescent: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil))
    let ascent = max(metrics.ascent, lineAscent)
    let descent = max(metrics.descent, lineDescent)
    let fontSize = style.size * typography.bodyPixelSize
    let lineHeight = fontSize * context.lineHeight
    let halfLeading = (lineHeight - ascent - descent) / 2
    var horizontalPad: CGFloat = 0
    var verticalPad: CGFloat = 0
    switch style.box {
    case .code:
      horizontalPad = typography.inlineCodePadding.width * fontSize
      verticalPad = typography.inlineCodePadding.height * fontSize
    case .keyboard:
      horizontalPad = typography.pixels(em: typography.keyboardPadding.width)
      verticalPad = typography.pixels(em: typography.keyboardPadding.height)
    case .mark, nil:
      break
    }
    let hanging = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
    let trailing = style.box == nil ? hanging : 0
    return ShapedSegment(
      range: (globalStart + range.lowerBound)..<(globalStart + range.upperBound), line: line,
      lineStart: range.lowerBound,
      style: TextStyle(color: style.color, decorations: style.decorations, box: style.box, link: style.link),
      width: width, trailingWhitespace: min(trailing, width), ascent: ascent, descent: descent, fontSize: fontSize,
      baselineShift: style.shift * fontSize, above: ascent + halfLeading, below: descent + halfLeading,
      leadingPad: isGroupStart ? horizontalPad : 0, trailingPad: isGroupEnd ? horizontalPad : 0,
      boxVerticalPad: verticalPad, breakAfter: breakAfter, boxGroup: style.group,
      affectsLineHeight: style.affectsLineHeight, bidiLevel: bidiLevel,
      drawOffset: inRightToLeftParagraph ? min(hanging, width) : 0)
  }

  private func finishRun(_ atoms: [Atom], base: SpanStyle, context: Context, isRightToLeft: Bool) -> Run {
    var words: [Word] = []
    var start = 0
    var advance: CGFloat = 0
    var visible: CGFloat = 0
    func close(_ end: Int) {
      if end > start { words.append(Word(atoms: start..<end, advance: advance, visible: visible, isHardBreak: false)) }
      start = end
      advance = 0
      visible = 0
    }
    for (index, atom) in atoms.enumerated() {
      switch atom {
      case .segment(let id):
        let segment = segments[id]
        visible = advance + segment.visibleAdvance
        advance += segment.advance
        if segment.breakAfter { close(index + 1) }
      case .anchor:
        continue
      case .image(let image):
        close(index)
        words.append(Word(atoms: index..<(index + 1), advance: 0, visible: 0, image: image, isHardBreak: false))
        start = index + 1
      case .hardBreak:
        close(index)
        words.append(Word(atoms: index..<(index + 1), advance: 0, visible: 0, isHardBreak: true))
        start = index + 1
      }
    }
    close(atoms.count)

    var minWidth: CGFloat = 0
    var maxWidth: CGFloat = 0
    var lineAdvance: CGFloat = 0
    for word in words {
      if word.isHardBreak {
        lineAdvance = 0
        continue
      }
      minWidth = max(minWidth, word.visible)
      maxWidth = max(maxWidth, lineAdvance + word.visible)
      lineAdvance += word.advance
    }
    let metrics = fonts.metrics(fontKey(base))
    let fontSize = base.size * typography.bodyPixelSize
    let halfLeading = (fontSize * context.lineHeight - metrics.ascent - metrics.descent) / 2
    return Run(
      atoms: atoms, words: words, strutAbove: metrics.ascent + halfLeading, strutBelow: metrics.descent + halfLeading,
      minWidth: minWidth, maxWidth: maxWidth, isRightToLeft: isRightToLeft)
  }

  private func label(_ value: String, style: SpanStyle, role: LabelRole) -> Int {
    let metrics = fonts.metrics(fontKey(style))
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: metrics.attributes))
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    labels.append(
      ShapedLabel(
        text: value, line: line, width: width, ascent: max(ascent, metrics.ascent),
        descent: max(descent, metrics.descent), role: role, color: style.color))
    return labels.count - 1
  }
}

private func romanNumeral(_ number: Int) -> String {
  guard number > 0, number < 4000 else { return "\(number)" }
  let table: [(Int, String)] = [
    (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"),
    (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
  ]
  var remaining = number
  var result = ""
  for (value, symbol) in table {
    while remaining >= value {
      result += symbol
      remaining -= value
    }
  }
  return result
}

private func alphabetic(_ number: Int) -> String {
  guard number > 0 else { return "\(number)" }
  var remaining = number
  var result = ""
  while remaining > 0 {
    remaining -= 1
    result = String(UnicodeScalar(UInt8(97 + remaining % 26))) + result
    remaining /= 26
  }
  return result
}
