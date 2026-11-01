import CoreGraphics
import MDViewerDocument

enum Atom {
  case segment(Int)
  case hardBreak
  case image(Int)
  case anchor(String)
}

struct Word {
  var atoms: Range<Int>
  var advance: CGFloat
  var visible: CGFloat
  var image: Int?
  var isHardBreak: Bool
}

struct Run {
  var atoms: [Atom]
  var words: [Word]
  var strutAbove: CGFloat
  var strutBelow: CGFloat
  var minWidth: CGFloat
  var maxWidth: CGFloat
}

struct ImageAtom {
  var image: Image
  var link: String?
  var block: BlockID
}

indirect enum Node {
  case heading(BlockID, level: Int, slug: String?, Run)
  case paragraph(BlockID, Run, isPlain: Bool)
  case quote(BlockID, [Node])
  case alert(BlockID, AlertKind, title: Int, [Node])
  case list(BlockID, ListNode)
  case code(BlockID, lines: [Run])
  case diagram(BlockID, code: String)
  case table(BlockID, TableNode)
  case footnote(BlockID, label: String, marker: Int, isFirst: Bool, [Node])
  case details(BlockID, summary: Run, [Node])
  case division(BlockID, TextAlignment, [Node])
  case rule(BlockID)
  case frontMatter(BlockID, [(key: Run, value: Run)])

  var id: BlockID {
    switch self {
    case .heading(let id, _, _, _), .paragraph(let id, _, _), .quote(let id, _), .alert(let id, _, _, _),
      .list(let id, _), .code(let id, _), .diagram(let id, _), .table(let id, _), .footnote(let id, _, _, _, _),
      .details(let id, _, _), .division(let id, _, _), .rule(let id), .frontMatter(let id, _):
      id
    }
  }
}

struct ListNode {
  var isTight: Bool
  var items: [ItemNode]
}

struct ItemNode {
  var id: BlockID
  var marker: Int?
  var task: TaskState?
  var children: [Node]
}

struct CellNode {
  var id: BlockID
  var children: [Node]
  var alignment: TableAlignment
  var columnSpan: Int
  var rowSpan: Int
}

struct TableNode {
  var rows: [[CellNode]]
  var headerRows: Int
}
