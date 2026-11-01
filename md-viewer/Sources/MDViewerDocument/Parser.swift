import cmark_gfm
import cmark_gfm_extensions

extension Document {
  public static func parse(_ markdown: String) -> Document {
    let split = FrontMatter.split(markdown)
    var converter = Converter(body: split.body, lineOffset: split.bodyLineOffset)
    return Document(frontMatter: split.entries, blocks: converter.convert())
  }
}

private typealias Node = UnsafeMutablePointer<cmark_node>

private struct Converter {
  let body: String
  let lines: [ArraySlice<UInt8>]
  let lineOffset: Int
  var slugger = Slugger()
  var footnoteLabels: [String] = []

  init(body: String, lineOffset: Int) {
    self.body = body
    self.lineOffset = lineOffset
    lines = Array(body.utf8).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
  }

  mutating func convert() -> [Block] {
    cmark_gfm_core_extensions_ensure_registered()
    guard let parser = cmark_parser_new(CMARK_OPT_SOURCEPOS | CMARK_OPT_FOOTNOTES) else { return [] }
    defer { cmark_parser_free(parser) }
    for name in ["table", "strikethrough", "autolink", "tasklist"] {
      if let extensionPointer = cmark_find_syntax_extension(name) {
        cmark_parser_attach_syntax_extension(parser, extensionPointer)
      }
    }
    let bytes = Array(body.utf8)
    bytes.withUnsafeBufferPointer { buffer in
      buffer.withMemoryRebound(to: CChar.self) { cmark_parser_feed(parser, $0.baseAddress, $0.count) }
    }
    guard let root = cmark_parser_finish(parser) else { return [] }
    defer { cmark_node_free(root) }
    footnoteLabels = children(root).filter { cmark_node_get_type($0) == CMARK_NODE_FOOTNOTE_DEFINITION }.map(literal)
    return blocks(root)
  }

  private func children(_ node: Node) -> [Node] {
    var result: [Node] = []
    var child = cmark_node_first_child(node)
    while let current = child {
      result.append(current)
      child = cmark_node_next(current)
    }
    return result
  }

  private func literal(_ node: Node) -> String {
    cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
  }

  private func typeString(_ node: Node) -> String {
    cmark_node_get_type_string(node).map { String(cString: $0) } ?? ""
  }

  private func range(_ node: Node) -> SourceRange {
    let startLine = Int(cmark_node_get_start_line(node))
    var startColumn = Int(cmark_node_get_start_column(node))
    var endLine = Int(cmark_node_get_end_line(node))
    var endColumn = Int(cmark_node_get_end_column(node))
    switch cmark_node_get_type(node) {
    case CMARK_NODE_HTML_BLOCK:
      let bytes = literal(node).utf8
      let newlines = bytes.filter { $0 == UInt8(ascii: "\n") }.count
      endLine = startLine + newlines - (bytes.last == UInt8(ascii: "\n") ? 1 : 0)
      endColumn = lineLength(endLine)
    case CMARK_NODE_FOOTNOTE_DEFINITION:
      startColumn = labelColumn(line: startLine, before: startColumn) ?? startColumn
    default:
      break
    }
    if endColumn == 0 && endLine > startLine {
      endLine -= 1
      endColumn = lineLength(endLine)
    }
    return SourceRange(
      start: SourcePosition(line: startLine + lineOffset, column: startColumn),
      end: SourcePosition(line: endLine + lineOffset, column: endColumn))
  }

  private func lineLength(_ line: Int) -> Int {
    guard lines.indices.contains(line - 1) else { return 0 }
    let bytes = lines[line - 1]
    return bytes.last == UInt8(ascii: "\r") ? bytes.count - 1 : bytes.count
  }

  private func labelColumn(line: Int, before column: Int) -> Int? {
    guard lines.indices.contains(line - 1) else { return nil }
    let bytes = Array(lines[line - 1].prefix(max(column - 1, 0)))
    guard bytes.count >= 2 else { return nil }
    return (0..<(bytes.count - 1)).last { bytes[$0] == UInt8(ascii: "[") && bytes[$0 + 1] == UInt8(ascii: "^") }
      .map { $0 + 1 }
  }

  private mutating func blocks(_ parent: Node) -> [Block] {
    var assembler = BlockAssembler()
    for child in children(parent) {
      if cmark_node_get_type(child) == CMARK_NODE_HTML_BLOCK {
        assembler.html(literal(child), range: range(child))
      } else if let block = block(child) {
        assembler.append(block)
      }
    }
    return assembler.finish()
  }

  private mutating func block(_ node: Node) -> Block? {
    let kind: Block.Kind
    switch cmark_node_get_type(node) {
    case CMARK_NODE_PARAGRAPH:
      kind = .paragraph(inlines(node))
    case CMARK_NODE_HEADING:
      let slug = slugger.slug(slugText(node))
      kind = .heading(Heading(level: Int(cmark_node_get_heading_level(node)), slug: slug, content: inlines(node)))
    case CMARK_NODE_BLOCK_QUOTE:
      kind = quote(node)
    case CMARK_NODE_LIST:
      kind = .list(list(node))
    case CMARK_NODE_CODE_BLOCK:
      let info = cmark_node_get_fence_info(node).map { String(cString: $0) } ?? ""
      var length: Int32 = 0
      var offset: Int32 = 0
      var character: CChar = 0
      let isFenced = cmark_node_get_fenced(node, &length, &offset, &character) != 0
      kind = .codeBlock(CodeBlock(info: info, code: literal(node), isFenced: isFenced))
    case CMARK_NODE_THEMATIC_BREAK:
      kind = .thematicBreak
    case CMARK_NODE_FOOTNOTE_DEFINITION:
      let label = literal(node)
      let number = (footnoteLabels.firstIndex(of: label) ?? footnoteLabels.count) + 1
      kind = .footnoteDefinition(FootnoteDefinition(label: label, number: number, blocks: blocks(node)))
    default:
      guard typeString(node) == "table" else { return nil }
      kind = .table(table(node))
    }
    return Block(kind, range: range(node))
  }

  private mutating func quote(_ node: Node) -> Block.Kind {
    var content = blocks(node)
    guard let first = cmark_node_first_child(node), cmark_node_get_type(first) == CMARK_NODE_PARAGRAPH,
      let kind = alertKind(firstLineOf: first), case .paragraph(let inlines)? = content.first?.kind
    else { return .blockQuote(content) }
    let remainder = inlines.drop { !$0.isBreak }.dropFirst()
    if remainder.isEmpty {
      content.removeFirst()
    } else {
      content[0].kind = .paragraph(Array(remainder))
    }
    return .alert(Alert(kind: kind, blocks: content))
  }

  private func alertKind(firstLineOf paragraph: Node) -> AlertKind? {
    let lineIndex = Int(cmark_node_get_start_line(paragraph)) - 1
    let column = Int(cmark_node_get_start_column(paragraph)) - 1
    guard lines.indices.contains(lineIndex) else { return nil }
    let line = lines[lineIndex]
    guard column >= 0, column <= line.count else { return nil }
    var text = String(decoding: line.dropFirst(column), as: UTF8.self)
    if text.hasSuffix("\r") { text.removeLast() }
    guard text.hasPrefix("[!"), let close = text.firstIndex(of: "]") else { return nil }
    let name = text[text.index(text.startIndex, offsetBy: 2)..<close]
    let rest = text[text.index(after: close)...]
    guard rest.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
    return AlertKind.allCases.first { $0.rawValue.uppercased() == name.uppercased() }
  }

  private mutating func list(_ node: Node) -> List {
    let kind: List.Kind =
      cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
      ? .ordered(start: Int(cmark_node_get_list_start(node))) : .bullet
    let items = children(node).map { item in
      let task: TaskState? =
        typeString(item) == "tasklist"
        ? (cmark_gfm_extensions_get_tasklist_item_checked(item) ? .checked : .unchecked) : nil
      return ListItem(task: task, blocks: blocks(item), range: range(item))
    }
    return List(kind: kind, isTight: cmark_node_get_list_tight(node) != 0, items: items)
  }

  private mutating func table(_ node: Node) -> Table {
    let columns = Int(cmark_gfm_extensions_get_table_columns(node))
    let alignments: [TableAlignment] = (0..<columns).map { index in
      switch cmark_gfm_extensions_get_table_alignments(node)?[index] {
      case UInt8(ascii: "l"): .left
      case UInt8(ascii: "c"): .center
      case UInt8(ascii: "r"): .right
      default: .none
      }
    }
    let rows = children(node).map { row in
      let rowRange = range(row)
      var cells = children(row).map { TableCell(content: inlines($0), range: range($0)) }
      while cells.count < columns {
        cells.append(TableCell(content: [], range: SourceRange(start: rowRange.end, end: rowRange.end)))
      }
      return TableRow(cells: cells, range: rowRange)
    }
    let header = rows.first ?? TableRow(cells: [], range: range(node))
    return Table(alignments: alignments, header: header, rows: Array(rows.dropFirst()))
  }

  private mutating func inlines(_ parent: Node) -> [Inline] {
    var builder = InlineBuilder()
    var previousEnd = range(parent).start
    for child in children(parent) {
      var childRange = range(child)
      if childRange.start.line == lineOffset {
        let start = SourcePosition(line: previousEnd.line, column: previousEnd.column + 1)
        childRange = SourceRange(start: start, end: start)
      }
      previousEnd = childRange.end
      switch cmark_node_get_type(child) {
      case CMARK_NODE_TEXT:
        builder.append(Inline(.text(literal(child)), range: childRange))
      case CMARK_NODE_SOFTBREAK:
        builder.append(Inline(.softBreak, range: childRange))
      case CMARK_NODE_LINEBREAK:
        builder.append(Inline(.hardBreak, range: childRange))
      case CMARK_NODE_CODE:
        builder.append(Inline(.code(literal(child)), range: childRange))
      case CMARK_NODE_HTML_INLINE:
        for token in HTMLTokenizer.tokenize(literal(child)) {
          builder.handle(token, range: childRange, decodingText: false)
        }
      case CMARK_NODE_EMPH:
        builder.append(Inline(.emphasis(inlines(child)), range: childRange))
      case CMARK_NODE_STRONG:
        builder.append(Inline(.strong(inlines(child)), range: childRange))
      case CMARK_NODE_LINK:
        builder.append(Inline(.link(link(child)), range: childRange))
      case CMARK_NODE_IMAGE:
        let image = Image(
          source: string(cmark_node_get_url(child)), title: string(cmark_node_get_title(child)),
          alt: inlines(child).plainText, width: nil, height: nil)
        builder.append(Inline(.image(image), range: childRange))
      case CMARK_NODE_FOOTNOTE_REFERENCE:
        let number = Int(literal(child)) ?? 0
        let label = footnoteLabels.indices.contains(number - 1) ? footnoteLabels[number - 1] : ""
        builder.append(Inline(.footnoteReference(label: label, number: number), range: childRange))
      default:
        if typeString(child) == "strikethrough" {
          builder.append(Inline(.strikethrough(inlines(child)), range: childRange))
        }
      }
    }
    return builder.finish(end: range(parent).end)
  }

  private mutating func link(_ node: Node) -> Link {
    let destination = string(cmark_node_get_url(node))
    let content = inlines(node)
    return Link(
      destination: destination, title: string(cmark_node_get_title(node)), content: content,
      isAutolink: isAutolink(node, destination: destination, content: content))
  }

  private func isAutolink(_ node: Node, destination: String, content: [Inline]) -> Bool {
    guard content.count == 1, case .text(let text) = content[0].kind,
      [text, "mailto:" + text, "http://" + text].contains(destination)
    else { return false }
    let lineIndex = Int(cmark_node_get_start_line(node)) - 1
    let column = Int(cmark_node_get_start_column(node)) - 1
    guard lines.indices.contains(lineIndex), lines[lineIndex].indices.contains(lines[lineIndex].startIndex + column)
    else { return true }
    return lines[lineIndex][lines[lineIndex].startIndex + column] != UInt8(ascii: "[")
  }

  private func slugText(_ node: Node) -> String {
    children(node).map { child -> String in
      switch cmark_node_get_type(child) {
      case CMARK_NODE_TEXT, CMARK_NODE_CODE: literal(child)
      case CMARK_NODE_IMAGE, CMARK_NODE_HTML_INLINE, CMARK_NODE_FOOTNOTE_REFERENCE, CMARK_NODE_SOFTBREAK,
        CMARK_NODE_LINEBREAK:
        ""
      default: slugText(child)
      }
    }.joined()
  }

  private func string(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
  }
}

extension Inline {
  fileprivate var isBreak: Bool {
    switch kind {
    case .softBreak, .hardBreak: true
    default: false
    }
  }
}

private struct BlockAssembler {
  private struct DetailsFrame {
    var isOpen: Bool
    var start: SourcePosition
    var end: SourcePosition
    var summary: [Inline]?
    var blocks: [Block] = []
  }

  private var output: [Block] = []
  private var frames: [DetailsFrame] = []

  mutating func append(_ block: Block) {
    if frames.isEmpty {
      output.append(block)
    } else {
      frames[frames.count - 1].blocks.append(block)
      frames[frames.count - 1].end = block.range.end
    }
  }

  mutating func html(_ source: String, range: SourceRange) {
    var pending = InlineBuilder()
    var summary: InlineBuilder?
    func flush() {
      let inlines = normalizedHTMLWhitespace(pending.finish(end: range.end))
      if !inlines.isEmpty { append(Block(.htmlBlock(inlines), range: range)) }
      pending = InlineBuilder()
    }
    func closeSummary() {
      guard var builder = summary else { return }
      frames[frames.count - 1].summary = normalizedHTMLWhitespace(builder.finish(end: range.end))
      summary = nil
    }
    for token in HTMLTokenizer.tokenize(source) {
      switch token {
      case .startTag("details", let attributes, _) where summary == nil:
        flush()
        frames.append(DetailsFrame(isOpen: attributes["open"] != nil, start: range.start, end: range.end))
      case .startTag("summary", _, _)
      where summary == nil && pending.isEmpty && frames.last.map { $0.summary == nil && $0.blocks.isEmpty } == true:
        summary = InlineBuilder()
      case .endTag("summary", _) where summary != nil:
        closeSummary()
      case .endTag("details", _) where !frames.isEmpty:
        closeSummary()
        flush()
        frames[frames.count - 1].end = range.end
        closeDetails()
      case .text(let text)
      where (summary?.isEmpty ?? pending.isEmpty) && text.unicodeScalars.allSatisfy(HTMLTokenizer.isSpace):
        continue
      default:
        if summary != nil {
          summary?.handle(token, range: range, decodingText: true)
        } else {
          pending.handle(token, range: range, decodingText: true)
        }
      }
    }
    closeSummary()
    flush()
    if !frames.isEmpty { frames[frames.count - 1].end = range.end }
  }

  mutating func finish() -> [Block] {
    while !frames.isEmpty { closeDetails() }
    return output
  }

  private mutating func closeDetails() {
    let frame = frames.removeLast()
    let details = Details(isOpen: frame.isOpen, summary: frame.summary ?? [], blocks: frame.blocks)
    append(Block(.details(details), range: SourceRange(start: frame.start, end: frame.end)))
  }
}

private func normalizedHTMLWhitespace(_ inlines: [Inline]) -> [Inline] {
  var result: [Inline] = inlines.map { inline in
    guard case .text(let text) = inline.kind else { return inline }
    return Inline(.text(collapsingWhitespace(text)), range: inline.range)
  }
  for index in result.indices {
    guard case .text(var text) = result[index].kind else { continue }
    if index == result.startIndex || result[index - 1].kind == .hardBreak { text = String(text.drop { $0 == " " }) }
    if index == result.index(before: result.endIndex) || result[index + 1].kind == .hardBreak {
      while text.last == " " { text.removeLast() }
    }
    result[index].kind = .text(text)
  }
  return result.filter { $0.kind != .text("") }
}

private func collapsingWhitespace(_ text: String) -> String {
  var result = ""
  var previousWasSpace = false
  for scalar in text.unicodeScalars {
    if HTMLTokenizer.isSpace(scalar) {
      if !previousWasSpace { result.append(" ") }
      previousWasSpace = true
    } else {
      result.unicodeScalars.append(scalar)
      previousWasSpace = false
    }
  }
  return result
}
