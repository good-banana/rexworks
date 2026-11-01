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
  case .link(let link):
    let name = link.isAutolink ? "autolink" : "link"
    let title = link.title.isEmpty ? "" : " title=\(link.title)"
    return "\(name)(\(link.destination)\(title): \(shape(link.content)))"
  case .image(let image):
    var attributes = ""
    if !image.title.isEmpty { attributes += " title=\(image.title)" }
    if let width = image.width { attributes += " width=\(width)" }
    if let height = image.height { attributes += " height=\(height)" }
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
  var htmlBlock: [Inline]? { if case .htmlBlock(let inlines) = kind { inlines } else { nil } }
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
  guard let first = document.blocks.first, let inlines = first.paragraph ?? first.htmlBlock else {
    XCTFail("expected a paragraph or HTML block", file: file, line: line)
    return ""
  }
  return shape(inlines)
}
