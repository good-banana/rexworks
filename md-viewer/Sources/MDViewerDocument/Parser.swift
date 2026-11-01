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
    let documentRange = range(root)
    let builder = TreeBuilder(range: documentRange)
    emitChildren(of: root, into: builder)
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

  private mutating func emitChildren(of parent: Node, into builder: TreeBuilder) {
    var previousEnd = range(parent).start
    for child in children(parent) {
      var childRange = range(child)
      if childRange.start.line == lineOffset {
        let start = SourcePosition(line: previousEnd.line, column: previousEnd.column + 1)
        childRange = SourceRange(start: start, end: start)
      }
      previousEnd = childRange.end
      emit(child, range: childRange, into: builder)
    }
  }

  private mutating func emitContainer(_ tag: MarkdownTag, _ node: Node, range: SourceRange, into builder: TreeBuilder) {
    builder.openMarkdown(tag, range: range)
    emitChildren(of: node, into: builder)
    builder.closeMarkdown(end: range.end)
  }

  private mutating func emit(_ node: Node, range: SourceRange, into builder: TreeBuilder) {
    switch cmark_node_get_type(node) {
    case CMARK_NODE_PARAGRAPH:
      emitContainer(.paragraph, node, range: range, into: builder)
    case CMARK_NODE_HEADING:
      let tag = MarkdownTag.heading(level: Int(cmark_node_get_heading_level(node)), slug: slugger.slug(slugText(node)))
      emitContainer(tag, node, range: range, into: builder)
    case CMARK_NODE_BLOCK_QUOTE:
      emitContainer(.blockQuote(alert: alertKind(node)), node, range: range, into: builder)
    case CMARK_NODE_LIST:
      let kind: List.Kind =
        cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
        ? .ordered(start: Int(cmark_node_get_list_start(node))) : .bullet
      emitContainer(.list(kind, isTight: cmark_node_get_list_tight(node) != 0), node, range: range, into: builder)
    case CMARK_NODE_ITEM:
      let task: TaskState? =
        typeString(node) == "tasklist"
        ? (cmark_gfm_extensions_get_tasklist_item_checked(node) ? .checked : .unchecked) : nil
      emitContainer(.item(task), node, range: range, into: builder)
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
    case CMARK_NODE_FOOTNOTE_DEFINITION:
      let label = literal(node)
      let number = (footnoteLabels.firstIndex(of: label) ?? footnoteLabels.count) + 1
      emitContainer(.footnoteDefinition(label: label, number: number), node, range: range, into: builder)
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
    case CMARK_NODE_EMPH:
      emitContainer(.emphasis, node, range: range, into: builder)
    case CMARK_NODE_STRONG:
      emitContainer(.strong, node, range: range, into: builder)
    case CMARK_NODE_LINK:
      let destination = string(cmark_node_get_url(node))
      let tag = MarkdownTag.link(
        destination: destination, title: string(cmark_node_get_title(node)),
        isAutolink: isAutolink(node, destination: destination))
      emitContainer(tag, node, range: range, into: builder)
    case CMARK_NODE_IMAGE:
      let tag = MarkdownTag.image(source: string(cmark_node_get_url(node)), title: string(cmark_node_get_title(node)))
      emitContainer(tag, node, range: range, into: builder)
    case CMARK_NODE_FOOTNOTE_REFERENCE:
      let number = Int(literal(node)) ?? 0
      let label = footnoteLabels.indices.contains(number - 1) ? footnoteLabels[number - 1] : ""
      builder.leafMarkdown(.footnoteReference(label: label, number: number), range: range)
    default:
      switch typeString(node) {
      case "table":
        let columns = Int(cmark_gfm_extensions_get_table_columns(node))
        let alignments: [TableAlignment] = (0..<columns).map { index in
          switch cmark_gfm_extensions_get_table_alignments(node)?[index] {
          case UInt8(ascii: "l"): .left
          case UInt8(ascii: "c"): .center
          case UInt8(ascii: "r"): .right
          default: .none
          }
        }
        emitContainer(.table(alignments), node, range: range, into: builder)
      case "table_header", "table_row":
        emitContainer(.tableRow, node, range: range, into: builder)
      case "table_cell":
        emitContainer(.tableCell, node, range: range, into: builder)
      case "strikethrough":
        emitContainer(.strikethrough, node, range: range, into: builder)
      default:
        break
      }
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
}
