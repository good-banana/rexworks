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
    let documentRange = shifted(rawRange(root))
    let builder = TreeBuilder(range: documentRange)
    emit(root, into: builder)
    return Lowering().blocks(builder.finish(end: documentRange.end).children)
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

  private func string(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
  }

  private func rawRange(_ node: Node) -> SourceRange {
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
      start: SourcePosition(line: startLine, column: clamped(startColumn, line: startLine)),
      end: SourcePosition(line: endLine, column: clamped(endColumn, line: endLine)))
  }

  private func clamped(_ column: Int, line: Int) -> Int {
    guard lines.indices.contains(line - 1) else { return column }
    return min(column, max(lineLength(line), 1))
  }

  private func shifted(_ range: SourceRange) -> SourceRange {
    SourceRange(
      start: SourcePosition(line: range.start.line + lineOffset, column: range.start.column),
      end: SourcePosition(line: range.end.line + lineOffset, column: range.end.column))
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

  private struct Cursor {
    var line: Int
    var index: Int
  }

  private struct Frame {
    var cursor: Cursor
    var closes: SourcePosition?
  }

  private mutating func emit(_ root: Node, into builder: TreeBuilder) {
    guard let iterator = cmark_iter_new(root) else { return }
    defer { cmark_iter_free(iterator) }
    var frames: [Frame] = []
    while true {
      let event = cmark_iter_next(iterator)
      guard event != CMARK_EVENT_DONE, let node = cmark_iter_get_node(iterator) else { break }
      if event == CMARK_EVENT_EXIT {
        if let end = frames.popLast()?.closes { builder.closeMarkdown(end: end) }
        continue
      }
      guard node != root else {
        let start = rawRange(root).start
        frames.append(Frame(cursor: Cursor(line: start.line, index: start.column - 1), closes: nil))
        continue
      }
      let cursor = frames[frames.count - 1].cursor
      let raw = locatedRange(node, after: cursor)
      frames[frames.count - 1].cursor = next(after: node, raw)
      let range = shifted(raw)
      if let tag = containerTag(node) {
        builder.openMarkdown(tag, range: range)
        frames.append(Frame(cursor: Cursor(line: raw.start.line, index: raw.start.column - 1), closes: range.end))
      } else {
        emitLeaf(node, range: range, into: builder)
        if !isLeaf(node) {
          frames.append(Frame(cursor: Cursor(line: raw.start.line, index: raw.start.column - 1), closes: nil))
        }
      }
    }
  }

  private func isLeaf(_ node: Node) -> Bool {
    switch cmark_node_get_type(node) {
    case CMARK_NODE_HTML_BLOCK, CMARK_NODE_THEMATIC_BREAK, CMARK_NODE_CODE_BLOCK, CMARK_NODE_TEXT,
      CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK, CMARK_NODE_CODE, CMARK_NODE_HTML_INLINE:
      true
    default:
      false
    }
  }

  private func next(after node: Node, _ range: SourceRange) -> Cursor {
    switch cmark_node_get_type(node) {
    case CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK: Cursor(line: range.start.line + 1, index: 0)
    default: Cursor(line: range.end.line, index: range.end.column)
    }
  }

  private func locatedRange(_ node: Node, after cursor: Cursor) -> SourceRange {
    let raw = rawRange(node)
    let point = SourceRange(
      start: SourcePosition(line: cursor.line, column: cursor.index + 1),
      end: SourcePosition(line: cursor.line, column: cursor.index + 1))
    switch cmark_node_get_type(node) {
    case CMARK_NODE_TEXT:
      return locate(literal(node), after: cursor, bracketed: false) ?? (raw.start.line == 0 ? point : raw)
    case CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK:
      let column = min(cursor.index + 1, max(lineLength(cursor.line), 1))
      let position = SourcePosition(line: cursor.line, column: column)
      return SourceRange(start: position, end: position)
    case CMARK_NODE_LINK:
      let content = children(node)
      if content.count == 1, cmark_node_get_type(content[0]) == CMARK_NODE_TEXT,
        isAutolink(node, destination: string(cmark_node_get_url(node))),
        let located = locate(literal(content[0]), after: cursor, bracketed: true)
      {
        return located
      }
      return raw.start.line == 0 ? point : raw
    default:
      return raw.start.line == 0 ? point : raw
    }
  }

  private func locate(_ text: String, after cursor: Cursor, bracketed: Bool) -> SourceRange? {
    guard lines.indices.contains(cursor.line - 1), !text.isEmpty else { return nil }
    let line = Array(lines[cursor.line - 1])
    let needle = Array(text.utf8)
    var index = max(cursor.index, 0)
    while index + needle.count <= line.count {
      if line[index..<(index + needle.count)].elementsEqual(needle) {
        var start = index
        var end = index + needle.count
        if bracketed, start > 0, line[start - 1] == UInt8(ascii: "<"), end < line.count,
          line[end] == UInt8(ascii: ">")
        {
          start -= 1
          end += 1
        }
        return SourceRange(
          start: SourcePosition(line: cursor.line, column: start + 1),
          end: SourcePosition(line: cursor.line, column: end))
      }
      index += 1
    }
    return nil
  }

  private mutating func containerTag(_ node: Node) -> MarkdownTag? {
    switch cmark_node_get_type(node) {
    case CMARK_NODE_PARAGRAPH:
      return .paragraph
    case CMARK_NODE_HEADING:
      return .heading(level: Int(cmark_node_get_heading_level(node)), slug: slugger.slug(slugText(node)))
    case CMARK_NODE_BLOCK_QUOTE:
      return .blockQuote(alert: alertKind(node))
    case CMARK_NODE_LIST:
      let kind: List.Kind =
        cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
        ? .ordered(start: Int(cmark_node_get_list_start(node))) : .bullet
      return .list(kind, isTight: cmark_node_get_list_tight(node) != 0)
    case CMARK_NODE_ITEM:
      let task: TaskState? =
        typeString(node) == "tasklist"
        ? (cmark_gfm_extensions_get_tasklist_item_checked(node) ? .checked : .unchecked) : nil
      return .item(task)
    case CMARK_NODE_FOOTNOTE_DEFINITION:
      let label = literal(node)
      return .footnoteDefinition(
        label: label, number: (footnoteLabels.firstIndex(of: label) ?? footnoteLabels.count) + 1)
    case CMARK_NODE_EMPH:
      return .emphasis
    case CMARK_NODE_STRONG:
      return .strong
    case CMARK_NODE_LINK:
      let destination = string(cmark_node_get_url(node))
      return .link(
        destination: destination, title: string(cmark_node_get_title(node)),
        isAutolink: isAutolink(node, destination: destination))
    case CMARK_NODE_IMAGE:
      return .image(source: string(cmark_node_get_url(node)), title: string(cmark_node_get_title(node)))
    default:
      switch typeString(node) {
      case "table":
        let columns = Int(cmark_gfm_extensions_get_table_columns(node))
        return .table(
          (0..<columns).map { index in
            switch cmark_gfm_extensions_get_table_alignments(node)?[index] {
            case UInt8(ascii: "l"): .left
            case UInt8(ascii: "c"): .center
            case UInt8(ascii: "r"): .right
            default: .none
            }
          })
      case "table_header", "table_row": return .tableRow
      case "table_cell": return .tableCell
      case "strikethrough": return .strikethrough
      default: return nil
      }
    }
  }

  private func emitLeaf(_ node: Node, range: SourceRange, into builder: TreeBuilder) {
    switch cmark_node_get_type(node) {
    case CMARK_NODE_CODE_BLOCK:
      var length: Int32 = 0
      var offset: Int32 = 0
      var character: CChar = 0
      let isFenced = cmark_node_get_fenced(node, &length, &offset, &character) != 0
      let code = CodeBlock(info: string(cmark_node_get_fence_info(node)), code: literal(node), isFenced: isFenced)
      builder.leafMarkdown(.codeBlock(code), range: range)
    case CMARK_NODE_HTML_BLOCK:
      for token in HTMLTokenizer.tokenize(literal(node)) { builder.html(token, range: range, fromBlock: true) }
    case CMARK_NODE_THEMATIC_BREAK:
      builder.leafMarkdown(.thematicBreak, range: range)
    case CMARK_NODE_TEXT:
      builder.text(literal(node), range: range, fromHTML: false)
    case CMARK_NODE_SOFTBREAK:
      builder.leafMarkdown(.softBreak, range: range)
    case CMARK_NODE_LINEBREAK:
      builder.leafMarkdown(.hardBreak, range: range)
    case CMARK_NODE_CODE:
      builder.leafMarkdown(.code(literal(node)), range: range)
    case CMARK_NODE_HTML_INLINE:
      for token in HTMLTokenizer.tokenize(literal(node)) { builder.html(token, range: range, fromBlock: false) }
    case CMARK_NODE_FOOTNOTE_REFERENCE:
      let number = Int(literal(node)) ?? 0
      let label = footnoteLabels.indices.contains(number - 1) ? footnoteLabels[number - 1] : ""
      builder.leafMarkdown(.footnoteReference(label: label, number: number), range: range)
    default:
      break
    }
  }

  private func alertKind(_ quote: Node) -> AlertKind? {
    guard let paragraph = cmark_node_first_child(quote), cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH
    else { return nil }
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

  private func isAutolink(_ node: Node, destination: String) -> Bool {
    let content = children(node)
    guard content.count == 1, cmark_node_get_type(content[0]) == CMARK_NODE_TEXT else { return false }
    let text = literal(content[0])
    guard [text, "mailto:" + text, "http://" + text].contains(destination) else { return false }
    let lineIndex = Int(cmark_node_get_start_line(node)) - 1
    let column = Int(cmark_node_get_start_column(node)) - 1
    guard lines.indices.contains(lineIndex), lines[lineIndex].indices.contains(lines[lineIndex].startIndex + column)
    else { return true }
    return lines[lineIndex][lines[lineIndex].startIndex + column] != UInt8(ascii: "[")
  }

  private func slugText(_ node: Node) -> String {
    guard let iterator = cmark_iter_new(node) else { return "" }
    defer { cmark_iter_free(iterator) }
    var text = ""
    var imageDepth = 0
    while true {
      let event = cmark_iter_next(iterator)
      guard event != CMARK_EVENT_DONE, let child = cmark_iter_get_node(iterator) else { break }
      switch cmark_node_get_type(child) {
      case CMARK_NODE_IMAGE:
        imageDepth += event == CMARK_EVENT_ENTER ? 1 : -1
      case CMARK_NODE_TEXT, CMARK_NODE_CODE:
        if imageDepth == 0 { text += literal(child) }
      default:
        break
      }
    }
    return text
  }
}
