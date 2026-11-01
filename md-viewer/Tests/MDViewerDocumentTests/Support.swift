import Foundation
import MDViewerDocument
import XCTest

func fixture(_ name: String) throws -> String {
  let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8)
}

func shape(_ inlines: [Inline]) -> String {
  inlines.map(shape).joined(separator: " ")
}

func shape(_ inline: Inline) -> String {
  switch inline.kind {
  case .text(let text): return "\"\(text)\""
  case .softBreak: return "soft"
  case .hardBreak: return "hard"
  case .code(let code): return "code(\"\(code)\")"
  case .emphasis(let children): return "em(\(shape(children)))"
  case .strong(let children): return "strong(\(shape(children)))"
  case .strikethrough(let children): return "del(\(shape(children)))"
  case .keyboard(let children): return "kbd(\(shape(children)))"
  case .subscript(let children): return "sub(\(shape(children)))"
  case .superscript(let children): return "sup(\(shape(children)))"
  case .inserted(let children): return "ins(\(shape(children)))"
  case .marked(let children): return "mark(\(shape(children)))"
  case .small(let children): return "small(\(shape(children)))"
  case .abbreviation(let title, let children): return "abbr(\(title): \(shape(children)))"
  case .link(let link):
    let name = link.isAutolink ? "autolink" : "link"
    let title = link.title.isEmpty ? "" : " title=\(link.title)"
    return "\(name)(\(link.destination)\(title): \(shape(link.content)))"
  case .image(let image):
    var attributes = ""
    if !image.title.isEmpty { attributes += " title=\(image.title)" }
    if let width = image.width { attributes += " width=\(width)" }
    if let height = image.height { attributes += " height=\(height)" }
    if !image.sources.isEmpty {
      let sources = image.sources.map { source in
        let scheme = source.colorScheme.map { "\($0)" } ?? "any"
        return "\(scheme):\(source.source)"
      }
      attributes += " sources=[\(sources.joined(separator: " "))]"
    }
    return "img(\(image.source)\(attributes): \"\(image.alt)\")"
  case .footnoteReference(let label, let number): return "fn(\(label) \(number))"
  }
}

extension Document {
  var kinds: [Block.Kind] { blocks.map(\.kind) }

  func headings() -> [Heading] {
    blocks.compactMap { if case .heading(let heading) = $0.kind { heading } else { nil } }
  }
}

extension Block {
  var paragraph: [Inline]? { if case .paragraph(let inlines) = kind { inlines } else { nil } }
  var plain: [Inline]? { if case .plain(let inlines) = kind { inlines } else { nil } }
  var division: Division? { if case .division(let division) = kind { division } else { nil } }
  var list: List? { if case .list(let list) = kind { list } else { nil } }
  var alert: Alert? { if case .alert(let alert) = kind { alert } else { nil } }
  var details: Details? { if case .details(let details) = kind { details } else { nil } }
  var codeBlock: CodeBlock? { if case .codeBlock(let code) = kind { code } else { nil } }
  var table: Table? { if case .table(let table) = kind { table } else { nil } }
  var heading: Heading? { if case .heading(let heading) = kind { heading } else { nil } }
  var footnote: FootnoteDefinition? {
    if case .footnoteDefinition(let footnote) = kind { footnote } else { nil }
  }
  var quote: [Block]? { if case .blockQuote(let blocks) = kind { blocks } else { nil } }
  var isThematicBreak: Bool { if case .thematicBreak = kind { true } else { false } }
}

func paragraphShape(_ markdown: String, file: StaticString = #filePath, line: UInt = #line) -> String {
  let document = Document.parse(markdown)
  guard let first = document.blocks.first, let inlines = first.paragraph ?? first.plain else {
    XCTFail("expected a paragraph or HTML block", file: file, line: line)
    return ""
  }
  return shape(inlines)
}

func shape(_ blocks: [Block]) -> String {
  blocks.map(shape).joined(separator: ", ")
}

func shape(_ block: Block) -> String {
  switch block.kind {
  case .heading(let heading): return "h\(heading.level)(\(shape(heading.content)))"
  case .paragraph(let inlines): return "p(\(shape(inlines)))"
  case .plain(let inlines): return "plain(\(shape(inlines)))"
  case .blockQuote(let blocks): return "quote[\(shape(blocks))]"
  case .alert(let alert): return "alert-\(alert.kind.rawValue)[\(shape(alert.blocks))]"
  case .list(let list):
    let name: String
    switch list.kind {
    case .bullet: name = "ul"
    case .ordered(let start): name = "ol(\(start))"
    }
    return "\(name)[\(list.items.map { "li[\(shape($0.blocks))]" }.joined(separator: ", "))]"
  case .codeBlock(let code): return "code(\(code.info): \"\(code.code)\")"
  case .table(let table):
    let header = table.header.map { "head: \(shape($0)); " } ?? ""
    return "table(\(header)\(table.rows.map(shape).joined(separator: "; ")))"
  case .footnoteDefinition(let footnote): return "footnote(\(footnote.label))[\(shape(footnote.blocks))]"
  case .details(let details):
    return "details(\(details.isOpen ? "open " : "")\(shape(details.summary)))[\(shape(details.blocks))]"
  case .division(let division): return "div(\(division.alignment))[\(shape(division.blocks))]"
  case .thematicBreak: return "hr"
  }
}

func shape(_ row: TableRow) -> String {
  row.cells.map { cell in
    var name = cell.isHeader ? "th" : "td"
    var attributes: [String] = []
    if cell.alignment != .none { attributes.append("\(cell.alignment)") }
    if cell.columnSpan != 1 { attributes.append("span=\(cell.columnSpan)") }
    if !attributes.isEmpty { name += "(\(attributes.joined(separator: " ")))" }
    return "\(name)[\(shape(cell.content))]"
  }.joined(separator: " ")
}

func cellText(_ cell: TableCell) -> String {
  cell.content.map { shape($0.plain ?? []) }.joined()
}
