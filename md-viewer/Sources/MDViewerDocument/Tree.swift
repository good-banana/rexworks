enum MarkdownTag {
  case paragraph
  case heading(level: Int, slug: String)
  case blockQuote(alert: AlertKind?)
  case list(List.Kind, isTight: Bool)
  case item(TaskState?)
  case codeBlock(CodeBlock)
  case thematicBreak
  case table([TableAlignment])
  case tableRow
  case tableCell
  case footnoteDefinition(label: String, number: Int)
  case emphasis
  case strong
  case strikethrough
  case code(String)
  case link(destination: String, title: String, isAutolink: Bool)
  case image(source: String, title: String)
  case softBreak
  case hardBreak
  case footnoteReference(label: String, number: Int)

  var isBlock: Bool {
    switch self {
    case .paragraph, .heading, .blockQuote, .list, .item, .codeBlock, .thematicBreak, .table, .tableRow, .tableCell,
      .footnoteDefinition:
      true
    default:
      false
    }
  }
}

enum TreeTag {
  case root
  case markdown(MarkdownTag)
  case html(String)
  case dropped(String)
}

final class TreeElement {
  let tag: TreeTag
  let attributes: [String: String]
  var children: [TreeNode] = []
  let start: SourcePosition
  var end: SourcePosition

  init(_ tag: TreeTag, attributes: [String: String] = [:], range: SourceRange) {
    self.tag = tag
    self.attributes = attributes
    start = range.start
    end = range.end
  }

  var range: SourceRange { SourceRange(start: start, end: end) }

  var htmlName: String? {
    if case .html(let name) = tag { name } else { nil }
  }

  var isMarkdown: Bool {
    if case .markdown = tag { true } else { false }
  }
}

enum TreeNode {
  case element(TreeElement)
  case text(String, SourceRange, fromHTML: Bool)

  var range: SourceRange {
    switch self {
    case .element(let element): element.range
    case .text(_, let range, _): range
    }
  }
}

enum HTMLVocabulary {
  static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
  static let blockLevel: Set<String> = headings.union([
    "div", "p", "center", "hr", "ul", "ol", "li", "table", "caption", "thead", "tbody", "tfoot", "tr", "td", "th",
    "blockquote", "pre", "details", "summary", "dl", "dt", "dd", "figure", "figcaption",
  ])
  static let inline: Set<String> = [
    "a", "img", "picture", "br", "wbr", "source", "b", "strong", "i", "em", "cite", "dfn", "var", "code", "tt", "samp",
    "kbd",
    "sub", "sup", "s", "del", "strike", "ins", "mark", "small", "abbr", "span", "q", "time", "bdo",
  ]
  static let void: Set<String> = ["br", "wbr", "hr", "img", "source"]
  static let dropped: Set<String> = [
    "script", "style", "iframe", "object", "embed", "form", "input", "button", "select", "option", "textarea",
    "noscript", "template", "frame", "frameset", "applet", "base", "link", "meta", "title", "xmp", "noembed",
    "noframes", "plaintext", "param",
  ]
  static let droppedVoid: Set<String> = ["embed", "input", "frame", "base", "link", "meta", "param"]
  static let closesParagraph: Set<String> = blockLevel.subtracting(["li", "td", "th", "tr", "summary"])
  static let allowedAttributes: Set<String> = [
    "align", "href", "title", "src", "srcset", "alt", "width", "height", "media", "open", "start", "colspan",
    "rowspan",
  ]

  static func isKnown(_ name: String) -> Bool {
    blockLevel.contains(name) || inline.contains(name)
  }
}

final class TreeBuilder {
  let root: TreeElement
  private var stack: [TreeElement]

  init(range: SourceRange) {
    root = TreeElement(.root, range: range)
    stack = [root]
  }

  private var current: TreeElement { stack[stack.count - 1] }

  func openMarkdown(_ tag: MarkdownTag, range: SourceRange) {
    if tag.isBlock { closeHTML(["p"], boundary: []) }
    let element = TreeElement(.markdown(tag), range: range)
    current.children.append(.element(element))
    stack.append(element)
  }

  func closeMarkdown(end: SourcePosition) {
    while stack.count > 1 {
      let element = stack.removeLast()
      if element.isMarkdown {
        element.end = end
        return
      }
      element.end = max(element.end, lastChildEnd(element))
    }
  }

  func leafMarkdown(_ tag: MarkdownTag, range: SourceRange) {
    if tag.isBlock { closeHTML(["p"], boundary: []) }
    current.children.append(.element(TreeElement(.markdown(tag), range: range)))
  }

  func text(_ text: String, range: SourceRange, fromHTML: Bool) {
    current.children.append(.text(text, range, fromHTML: fromHTML))
  }

  func html(_ token: HTMLToken, range: SourceRange, fromBlock: Bool) {
    switch token {
    case .comment:
      break
    case .text(let text):
      self.text(fromBlock ? HTMLEntities.decode(text) : text, range: range, fromHTML: fromBlock)
    case .startTag(let name, let attributes, let source):
      start(name, attributes: attributes, source: source, range: range, fromBlock: fromBlock)
    case .endTag(let name, let source):
      if HTMLVocabulary.isKnown(name) || HTMLVocabulary.dropped.contains(name) {
        guard name != "br" else {
          current.children.append(.element(TreeElement(.html("br"), range: range)))
          return
        }
        closeHTML([name], boundary: [], explicitEnd: range.end)
      } else {
        text(source, range: range, fromHTML: fromBlock)
      }
    }
  }

  private func start(
    _ name: String, attributes: [String: String], source: String, range: SourceRange, fromBlock: Bool
  ) {
    if HTMLVocabulary.dropped.contains(name) {
      guard !HTMLVocabulary.droppedVoid.contains(name) else { return }
      let element = TreeElement(.dropped(name), range: range)
      current.children.append(.element(element))
      stack.append(element)
      return
    }
    guard HTMLVocabulary.isKnown(name) else {
      text(source, range: range, fromHTML: fromBlock)
      return
    }
    if HTMLVocabulary.closesParagraph.contains(name) { closeHTML(["p"], boundary: []) }
    switch name {
    case "li":
      closeHTML(["li"], boundary: ["ul", "ol"])
    case "dt", "dd":
      closeHTML(["dt", "dd"], boundary: ["dl"])
    case "tr":
      closeHTML(["tr"], boundary: ["table", "thead", "tbody", "tfoot"])
    case "td", "th":
      closeHTML(["td", "th"], boundary: ["tr", "table"])
    case "thead", "tbody", "tfoot":
      closeHTML(["thead", "tbody", "tfoot"], boundary: ["table"])
    default:
      if HTMLVocabulary.headings.contains(name), let open = current.htmlName, HTMLVocabulary.headings.contains(open) {
        closeHTML([open], boundary: [])
      }
    }
    let kept = attributes.filter { HTMLVocabulary.allowedAttributes.contains($0.key) }
    let element = TreeElement(.html(name), attributes: kept, range: range)
    current.children.append(.element(element))
    if !HTMLVocabulary.void.contains(name) { stack.append(element) }
  }

  private func closeHTML(_ names: Set<String>, boundary: Set<String>, explicitEnd: SourcePosition? = nil) {
    var index = stack.count - 1
    while index > 0 {
      let element = stack[index]
      if element.isMarkdown { return }
      let name: String
      switch element.tag {
      case .html(let html): name = html
      case .dropped(let dropped): name = dropped
      default: return
      }
      if names.contains(name) { break }
      if boundary.contains(name) { return }
      index -= 1
    }
    guard index > 0 else { return }
    while stack.count > index {
      let element = stack.removeLast()
      element.end = stack.count == index ? (explicitEnd ?? lastChildEnd(element)) : lastChildEnd(element)
    }
  }

  private func lastChildEnd(_ element: TreeElement) -> SourcePosition {
    element.children.last.map { max(element.end, $0.range.end) } ?? element.end
  }

  func finish(end: SourcePosition) -> TreeElement {
    while stack.count > 1 {
      let element = stack.removeLast()
      element.end = max(element.end, lastChildEnd(element))
    }
    root.end = end
    return root
  }
}

extension SourcePosition: Comparable {
  public static func < (lhs: SourcePosition, rhs: SourcePosition) -> Bool {
    (lhs.line, lhs.column) < (rhs.line, rhs.column)
  }
}
