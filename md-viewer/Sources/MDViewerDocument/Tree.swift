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
  var closedExplicitly = false

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

  var elementName: String? {
    switch tag {
    case .html(let name), .dropped(let name): name
    default: nil
    }
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
    "sub", "sup", "s", "del", "strike", "ins", "mark", "small", "abbr", "span", "q", "time", "bdo", "video",
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
    "rowspan", "id", "name", "poster",
  ]

  static func isKnown(_ name: String) -> Bool {
    blockLevel.contains(name) || inline.contains(name)
  }
}

final class TreeBuilder {
  static let maximumDepth = 100

  let root: TreeElement
  private var stack: [TreeElement]
  private var markdownOpens: [Bool] = []
  private var openCounts: [String: Int] = [:]
  private var hidden: [(name: String, level: Int)] = []

  init(range: SourceRange) {
    root = TreeElement(.root, range: range)
    stack = [root]
  }

  private var current: TreeElement { stack[stack.count - 1] }
  private var isFull: Bool { stack.count > Self.maximumDepth }

  func openMarkdown(_ tag: MarkdownTag, range: SourceRange) {
    if tag.isBlock {
      closeHTML(["p"], boundary: [])
      hidden.removeAll()
    }
    guard !isFull, hidden.isEmpty else {
      markdownOpens.append(false)
      return
    }
    let element = TreeElement(.markdown(tag), range: range)
    current.children.append(.element(element))
    push(element)
    markdownOpens.append(true)
  }

  func closeMarkdown(end: SourcePosition) {
    let opened = markdownOpens.popLast()
    hidden.removeAll { $0.level > markdownOpens.count }
    guard opened == true else { return }
    while stack.count > 1 {
      let element = pop()
      if element.isMarkdown {
        element.end = end
        return
      }
      element.end = max(element.end, lastChildEnd(element))
    }
  }

  func leafMarkdown(_ tag: MarkdownTag, range: SourceRange) {
    if tag.isBlock {
      closeHTML(["p"], boundary: [])
      hidden.removeAll()
    }
    guard hidden.isEmpty else { return }
    current.children.append(.element(TreeElement(.markdown(tag), range: range)))
  }

  func text(_ text: String, range: SourceRange, fromHTML: Bool) {
    guard hidden.isEmpty else { return }
    current.children.append(.text(text, range, fromHTML: fromHTML))
  }

  func html(_ token: HTMLToken, range: SourceRange, fromBlock: Bool) {
    if !hidden.isEmpty || isFull, trackHidden(token) { return }
    switch token {
    case .comment:
      break
    case .text(let text):
      self.text(fromBlock ? HTMLEntities.decode(text) : text, range: range, fromHTML: fromBlock)
    case .startTag(let name, let attributes):
      start(name, attributes: attributes, range: range)
    case .endTag("br"):
      current.children.append(.element(TreeElement(.html("br"), range: range)))
    case .endTag(let name):
      closeHTML([name], boundary: [], explicitEnd: range.end)
    }
  }

  private func start(_ name: String, attributes: [String: String], range: SourceRange) {
    if name == "iframe", !isFull, let source = attributes["src"], VideoEmbed(source: source) != nil {
      current.children.append(.element(TreeElement(.html("iframe"), attributes: ["src": source], range: range)))
    }
    if HTMLVocabulary.dropped.contains(name) {
      guard !HTMLVocabulary.droppedVoid.contains(name), !isFull else { return }
      let element = TreeElement(.dropped(name), range: range)
      current.children.append(.element(element))
      push(element)
      return
    }
    guard HTMLVocabulary.isKnown(name) else { return }
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
    let isVoid = HTMLVocabulary.void.contains(name)
    guard isVoid || !isFull else { return }
    let kept = attributes.filter { HTMLVocabulary.allowedAttributes.contains($0.key) }
    let element = TreeElement(.html(name), attributes: kept, range: range)
    current.children.append(.element(element))
    if !isVoid { push(element) }
  }

  private func trackHidden(_ token: HTMLToken) -> Bool {
    switch token {
    case .startTag(let name, _)
    where HTMLVocabulary.dropped.contains(name) && !HTMLVocabulary.droppedVoid.contains(name):
      hidden.append((name, markdownOpens.count))
      return true
    case .endTag(let name):
      guard let index = hidden.lastIndex(where: { $0.name == name }) else { return !hidden.isEmpty }
      hidden.removeSubrange(index...)
      return true
    default:
      return !hidden.isEmpty
    }
  }

  private func push(_ element: TreeElement) {
    stack.append(element)
    if let name = element.elementName { openCounts[name, default: 0] += 1 }
  }

  private func pop() -> TreeElement {
    let element = stack.removeLast()
    if let name = element.elementName { openCounts[name, default: 1] -= 1 }
    return element
  }

  private func closeHTML(_ names: Set<String>, boundary: Set<String>, explicitEnd: SourcePosition? = nil) {
    guard names.contains(where: { openCounts[$0, default: 0] > 0 }) else { return }
    var index = stack.count - 1
    while index > 0 {
      let element = stack[index]
      guard let name = element.elementName else { return }
      if names.contains(name) { break }
      if boundary.contains(name) { return }
      index -= 1
    }
    guard index > 0 else { return }
    while stack.count > index {
      let element = pop()
      if stack.count == index {
        element.end = explicitEnd ?? lastChildEnd(element)
        element.closedExplicitly = explicitEnd != nil
      } else {
        element.end = lastChildEnd(element)
      }
    }
  }

  private func lastChildEnd(_ element: TreeElement) -> SourcePosition {
    element.children.last.map { max(element.end, $0.range.end) } ?? element.end
  }

  func finish(end: SourcePosition) -> TreeElement {
    while stack.count > 1 {
      let element = pop()
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
