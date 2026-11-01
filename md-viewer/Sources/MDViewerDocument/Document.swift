public struct SourcePosition: Hashable, Sendable {
  public var line: Int
  public var column: Int

  public init(line: Int, column: Int) {
    self.line = line
    self.column = column
  }
}

public struct SourceRange: Hashable, Sendable {
  public var start: SourcePosition
  public var end: SourcePosition

  public init(start: SourcePosition, end: SourcePosition) {
    self.start = start
    self.end = end
  }
}

public struct FrontMatterEntry: Hashable, Sendable {
  public var key: String
  public var value: String

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }
}

public struct Document: Hashable, Sendable {
  public var frontMatter: [FrontMatterEntry]
  public var blocks: [Block]

  public init(frontMatter: [FrontMatterEntry], blocks: [Block]) {
    self.frontMatter = frontMatter
    self.blocks = blocks
  }
}

public struct Block: Hashable, Sendable {
  public indirect enum Kind: Hashable, Sendable {
    case heading(Heading)
    case paragraph([Inline])
    case blockQuote([Block])
    case alert(Alert)
    case list(List)
    case codeBlock(CodeBlock)
    case table(Table)
    case footnoteDefinition(FootnoteDefinition)
    case details(Details)
    case division(Division)
    case plain([Inline])
    case thematicBreak
  }

  public var kind: Kind
  public var range: SourceRange

  public init(_ kind: Kind, range: SourceRange) {
    self.kind = kind
    self.range = range
  }
}

public struct Heading: Hashable, Sendable {
  public var level: Int
  public var slug: String?
  public var content: [Inline]
}

public enum TextAlignment: Hashable, Sendable {
  case left, center, right, justify
}

public struct Division: Hashable, Sendable {
  public var alignment: TextAlignment
  public var blocks: [Block]
}

public enum AlertKind: String, CaseIterable, Hashable, Sendable {
  case note, tip, important, warning, caution

  public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

public struct Alert: Hashable, Sendable {
  public var kind: AlertKind
  public var blocks: [Block]
}

public struct List: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case bullet
    case ordered(start: Int)
  }

  public var kind: Kind
  public var isTight: Bool
  public var items: [ListItem]
}

public enum TaskState: Hashable, Sendable {
  case unchecked
  case checked
}

public struct ListItem: Hashable, Sendable {
  public var task: TaskState?
  public var blocks: [Block]
  public var range: SourceRange
}

public struct CodeBlock: Hashable, Sendable {
  public var info: String
  public var code: String
  public var isFenced: Bool

  public init(info: String, code: String, isFenced: Bool) {
    self.info = info
    self.code = code
    self.isFenced = isFenced
  }

  public var language: String? {
    info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
  }
}

public enum TableAlignment: Hashable, Sendable {
  case none, left, center, right
}

public struct TableCell: Hashable, Sendable {
  public var content: [Block]
  public var alignment: TableAlignment
  public var isHeader: Bool
  public var columnSpan: Int
  public var rowSpan: Int
  public var range: SourceRange
}

public struct TableRow: Hashable, Sendable {
  public var cells: [TableCell]
  public var range: SourceRange
}

public struct Table: Hashable, Sendable {
  public var alignments: [TableAlignment]
  public var header: TableRow?
  public var rows: [TableRow]
}

public struct FootnoteDefinition: Hashable, Sendable {
  public var label: String
  public var number: Int
  public var blocks: [Block]
}

public struct Details: Hashable, Sendable {
  public var isOpen: Bool
  public var summary: [Inline]
  public var blocks: [Block]
}

public struct Inline: Hashable, Sendable {
  public indirect enum Kind: Hashable, Sendable {
    case text(String)
    case softBreak
    case hardBreak
    case code(String)
    case emphasis([Inline])
    case strong([Inline])
    case strikethrough([Inline])
    case keyboard([Inline])
    case `subscript`([Inline])
    case superscript([Inline])
    case inserted([Inline])
    case marked([Inline])
    case small([Inline])
    case abbreviation(title: String, content: [Inline])
    case link(Link)
    case image(Image)
    case footnoteReference(label: String, number: Int)
    case anchor(String)
  }

  public var kind: Kind
  public var range: SourceRange

  public init(_ kind: Kind, range: SourceRange) {
    self.kind = kind
    self.range = range
  }
}

public struct Link: Hashable, Sendable {
  public var destination: String
  public var title: String
  public var content: [Inline]
  public var isAutolink: Bool
}

public struct Image: Hashable, Sendable {
  public var source: String
  public var title: String
  public var alt: String
  public var width: Int?
  public var height: Int?
  public var sources: [ImageSource]
}

public enum ColorScheme: Hashable, Sendable {
  case light, dark
}

public struct ImageSource: Hashable, Sendable {
  public var source: String
  public var media: String
  public var colorScheme: ColorScheme?
}

extension Inline {
  public var plainText: String {
    switch kind {
    case .text(let text), .code(let text): text
    case .softBreak: " "
    case .hardBreak: "\n"
    case .emphasis(let children), .strong(let children), .strikethrough(let children), .keyboard(let children),
      .subscript(let children), .superscript(let children), .inserted(let children), .marked(let children),
      .small(let children), .abbreviation(_, let children):
      children.plainText
    case .link(let link): link.content.plainText
    case .image(let image): image.alt
    case .footnoteReference(_, let number): "[\(number)]"
    case .anchor: ""
    }
  }
}

extension Array where Element == Inline {
  public var plainText: String { map(\.plainText).joined() }
}

extension Document {
  public static let anchorPrefix = "user-content-"

  public var anchorNames: [String] {
    var names: [String] = []
    var pending = Array(blocks.reversed())
    while let block = pending.popLast() {
      switch block.kind {
      case .heading(let heading):
        if let slug = heading.slug { names.append(slug) }
        names += anchors(in: heading.content)
      case .paragraph(let inlines), .plain(let inlines):
        names += anchors(in: inlines)
      case .blockQuote(let children):
        pending += children.reversed()
      case .alert(let alert):
        pending += alert.blocks.reversed()
      case .list(let list):
        pending += list.items.flatMap(\.blocks).reversed()
      case .table(let table):
        let rows = (table.header.map { [$0] } ?? []) + table.rows
        pending += rows.flatMap(\.cells).flatMap(\.content).reversed()
      case .footnoteDefinition(let footnote):
        pending += footnote.blocks.reversed()
      case .details(let details):
        names += anchors(in: details.summary)
        pending += details.blocks.reversed()
      case .division(let division):
        pending += division.blocks.reversed()
      case .codeBlock, .thematicBreak:
        break
      }
    }
    return names
  }

  public func resolveAnchor(_ fragment: String) -> String? {
    let name = fragment.hasPrefix("#") ? String(fragment.dropFirst()) : fragment
    let names = Set(anchorNames)
    if names.contains(name) { return name }
    if name.hasPrefix(Self.anchorPrefix) {
      let bare = String(name.dropFirst(Self.anchorPrefix.count))
      if names.contains(bare) { return bare }
    }
    return nil
  }

  private func anchors(in inlines: [Inline]) -> [String] {
    var names: [String] = []
    var pending = Array(inlines.reversed())
    while let inline = pending.popLast() {
      switch inline.kind {
      case .anchor(let name):
        names.append(name)
      case .emphasis(let children), .strong(let children), .strikethrough(let children), .keyboard(let children),
        .subscript(let children), .superscript(let children), .inserted(let children), .marked(let children),
        .small(let children), .abbreviation(_, let children):
        pending += children.reversed()
      case .link(let link):
        pending += link.content.reversed()
      default:
        break
      }
    }
    return names
  }
}
