struct Lowering {
  private enum Role { case block, inline, skip }

  func blocks(_ nodes: [TreeNode]) -> [Block] {
    var result: [Block] = []
    var run: [TreeNode] = []
    func flushRun() {
      defer { run = [] }
      let content = normalizedHTMLRun(inlines(run))
      guard !content.isEmpty, let first = run.first, let last = run.last else { return }
      result.append(Block(.plain(content), range: SourceRange(start: first.range.start, end: last.range.end)))
    }
    for node in expanded(nodes) {
      switch role(node) {
      case .inline:
        run.append(node)
      case .skip:
        continue
      case .block:
        flushRun()
        if case .element(let element) = node { result += blocks(of: element) }
      }
    }
    flushRun()
    return result
  }

  private func role(_ node: TreeNode) -> Role {
    guard case .element(let element) = node else { return .inline }
    switch element.tag {
    case .root: return .block
    case .dropped: return .skip
    case .markdown(let tag): return tag.isBlock ? .block : .inline
    case .html(let name): return HTMLVocabulary.blockLevel.contains(name) ? .block : .inline
    }
  }

  private func blocks(of element: TreeElement) -> [Block] {
    let range = element.range
    switch element.tag {
    case .root, .dropped:
      return []
    case .markdown(let tag):
      return markdownBlocks(tag, element)
    case .html(let name):
      return htmlBlocks(name, element, range: range)
    }
  }

  private func markdownBlocks(_ tag: MarkdownTag, _ element: TreeElement) -> [Block] {
    let range = element.range
    switch tag {
    case .paragraph:
      let content = inlines(element.children)
      guard !content.allSatisfy(\.isBlank) else { return [] }
      return [Block(.paragraph(content), range: range)]
    case .heading(let level, let slug):
      return [Block(.heading(Heading(level: level, slug: slug, content: inlines(element.children))), range: range)]
    case .blockQuote(let alert):
      return [Block(quote(blocks(element.children), alert: alert), range: range)]
    case .list(let kind, let isTight):
      let items = element.children.compactMap { node -> ListItem? in
        guard case .element(let item) = node, case .markdown(.item(let task)) = item.tag else { return nil }
        return ListItem(task: task, blocks: blocks(item.children), range: item.range)
      }
      return [Block(.list(List(kind: kind, isTight: isTight, items: items)), range: range)]
    case .item:
      return blocks(element.children)
    case .codeBlock(let code):
      return [Block(.codeBlock(code), range: range)]
    case .thematicBreak:
      return [Block(.thematicBreak, range: range)]
    case .table(let alignments):
      return [Block(.table(markdownTable(element, alignments: alignments)), range: range)]
    case .footnoteDefinition(let label, let number):
      let footnote = FootnoteDefinition(label: label, number: number, blocks: blocks(element.children))
      return [Block(.footnoteDefinition(footnote), range: range)]
    default:
      return blocks(element.children)
    }
  }

  private func quote(_ content: [Block], alert: AlertKind?) -> Block.Kind {
    guard let alert else { return .blockQuote(content) }
    var content = content
    if case .paragraph(let inlines)? = content.first?.kind {
      let remainder = inlines.drop { !$0.isBreak }.dropFirst()
      if remainder.isEmpty {
        content.removeFirst()
      } else {
        content[0].kind = .paragraph(Array(remainder))
      }
    }
    return .alert(Alert(kind: alert, blocks: content))
  }

  private func markdownTable(_ element: TreeElement, alignments: [TableAlignment]) -> Table {
    let rows = childElements(element).enumerated().map { rowIndex, row in
      var cells = childElements(row).enumerated().map { column, cell in
        let content = inlines(cell.children)
        return TableCell(
          content: content.isEmpty ? [] : [Block(.plain(content), range: cell.range)],
          alignment: column < alignments.count ? alignments[column] : .none, isHeader: rowIndex == 0,
          columnSpan: 1, rowSpan: 1, range: cell.range)
      }
      while cells.count < alignments.count {
        cells.append(
          TableCell(
            content: [], alignment: alignments[cells.count], isHeader: rowIndex == 0, columnSpan: 1, rowSpan: 1,
            range: SourceRange(start: row.end, end: row.end)))
      }
      return TableRow(cells: cells, range: row.range)
    }
    return Table(alignments: alignments, header: rows.first, rows: Array(rows.dropFirst()))
  }

  private func htmlBlocks(_ name: String, _ element: TreeElement, range: SourceRange) -> [Block] {
    let alignment = textAlignment(element)
    switch name {
    case "p":
      let content = normalizedHTMLRun(inlines(element.children))
      guard !content.isEmpty else { return [] }
      return aligned(Block(.paragraph(content), range: range), alignment)
    case _ where HTMLVocabulary.headings.contains(name):
      let level = Int(String(name.dropFirst())) ?? 1
      let heading = Heading(
        level: level, slug: element.attributes["id"], content: normalizedHTMLRun(inlines(element.children)))
      return aligned(Block(.heading(heading), range: range), alignment)
    case "div", "center":
      let content = blocks(element.children)
      guard let alignment = name == "center" ? .center : alignment else { return content }
      return [Block(.division(Division(alignment: alignment, blocks: content)), range: range)]
    case "hr":
      return [Block(.thematicBreak, range: range)]
    case "ul", "ol":
      return [Block(.list(htmlList(element, ordered: name == "ol")), range: range)]
    case "table":
      return htmlTable(element)
    case "blockquote":
      return [Block(.blockQuote(blocks(element.children)), range: range)]
    case "pre":
      var code = preformattedText(element.children)
      if code.hasPrefix("\r\n") {
        code.removeFirst()
      } else if code.hasPrefix("\n") {
        code.removeFirst()
      }
      if !code.isEmpty && !code.hasSuffix("\n") { code += "\n" }
      return [Block(.codeBlock(CodeBlock(info: "", code: code, isFenced: false)), range: range)]
    case "details":
      var summary: [Inline]?
      var body: [TreeNode] = []
      for node in expanded(element.children) {
        if summary == nil, case .element(let child) = node, child.htmlName == "summary" {
          summary = normalizedHTMLRun(inlines(child.children))
        } else {
          body.append(node)
        }
      }
      let details = Details(isOpen: element.attributes["open"] != nil, summary: summary ?? [], blocks: blocks(body))
      return [Block(.details(details), range: range)]
    default:
      return blocks(element.children)
    }
  }

  private func aligned(_ block: Block, _ alignment: TextAlignment?) -> [Block] {
    guard let alignment else { return [block] }
    return [Block(.division(Division(alignment: alignment, blocks: [block])), range: block.range)]
  }

  private func textAlignment(_ element: TreeElement) -> TextAlignment? {
    switch element.attributes["align"]?.lowercased() {
    case "left": .left
    case "center", "middle": .center
    case "right": .right
    case "justify": .justify
    default: nil
    }
  }

  private func htmlList(_ element: TreeElement, ordered: Bool) -> List {
    var items: [ListItem] = []
    var stray: [TreeNode] = []
    func flushStray() {
      defer { stray = [] }
      let content = blocks(stray)
      guard let first = content.first, let last = content.last else { return }
      items.append(
        ListItem(task: nil, blocks: content, range: SourceRange(start: first.range.start, end: last.range.end)))
    }
    for node in expanded(element.children) {
      if case .element(let child) = node, child.htmlName == "li" {
        flushStray()
        items.append(ListItem(task: nil, blocks: blocks(child.children), range: child.range))
      } else {
        stray.append(node)
      }
    }
    flushStray()
    let start = element.attributes["start"].flatMap { Int($0) } ?? 1
    return List(kind: ordered ? .ordered(start: start) : .bullet, isTight: true, items: items)
  }

  private func htmlTable(_ element: TreeElement) -> [Block] {
    var caption: [Block] = []
    var rows: [(row: TreeElement, inHead: Bool)] = []
    for child in childElements(element) {
      switch child.htmlName {
      case "caption": caption += blocks(child.children)
      case "tr": rows.append((child, false))
      case "thead", "tbody", "tfoot":
        rows += childElements(child).filter { $0.htmlName == "tr" }.map { ($0, child.htmlName == "thead") }
      default: break
      }
    }
    let tableRows = rows.map { entry in
      let rowAlignment = tableAlignment(entry.row)
      let cells = childElements(entry.row).filter { $0.htmlName == "td" || $0.htmlName == "th" }.map { cell in
        TableCell(
          content: blocks(cell.children), alignment: tableAlignment(cell) ?? rowAlignment ?? .none,
          isHeader: cell.htmlName == "th", columnSpan: max(1, cell.attributes["colspan"].flatMap { Int($0) } ?? 1),
          rowSpan: max(1, cell.attributes["rowspan"].flatMap { Int($0) } ?? 1), range: cell.range)
      }
      return TableRow(cells: cells, range: entry.row.range)
    }
    guard let first = tableRows.first else { return caption }
    let headed = rows[0].inHead || first.cells.allSatisfy(\.isHeader)
    let table = Table(
      alignments: first.cells.map(\.alignment), header: headed ? first : nil,
      rows: headed ? Array(tableRows.dropFirst()) : tableRows)
    return caption + [Block(.table(table), range: element.range)]
  }

  private func tableAlignment(_ element: TreeElement) -> TableAlignment? {
    switch textAlignment(element) {
    case .left: .left
    case .center: .center
    case .right: .right
    default: nil
    }
  }

  private func childElements(_ element: TreeElement) -> [TreeElement] {
    expanded(element.children).compactMap { if case .element(let child) = $0 { child } else { nil } }
  }

  private func expanded(_ nodes: [TreeNode]) -> [TreeNode] {
    var result: [TreeNode] = []
    var pending = Array(nodes.reversed())
    while let node = pending.popLast() {
      guard case .element(let element) = node, case .dropped = element.tag else {
        result.append(node)
        continue
      }
      if !element.closedExplicitly { pending += element.children.reversed() }
    }
    return result
  }

  private func preformattedText(_ nodes: [TreeNode]) -> String {
    expanded(nodes).map { node -> String in
      switch node {
      case .text(let text, _, _): return text
      case .element(let element):
        if case .dropped = element.tag { return "" }
        return element.htmlName == "br" ? "\n" : preformattedText(element.children)
      }
    }.joined()
  }

  func inlines(_ nodes: [TreeNode]) -> [Inline] {
    var result: [Inline] = []
    for node in expanded(nodes) {
      switch node {
      case .text(let text, let range, let fromHTML):
        append(Inline(.text(fromHTML ? collapsingWhitespace(text) : text), range: range), to: &result)
      case .element(let element):
        for inline in inlines(of: element) { append(inline, to: &result) }
      }
    }
    return result
  }

  private func inlines(of element: TreeElement) -> [Inline] {
    let range = element.range
    let children = { inlines(element.children) }
    switch element.tag {
    case .root, .dropped:
      return []
    case .markdown(let tag):
      switch tag {
      case .emphasis: return [Inline(.emphasis(children()), range: range)]
      case .strong: return [Inline(.strong(children()), range: range)]
      case .strikethrough: return [Inline(.strikethrough(children()), range: range)]
      case .code(let code): return [Inline(.code(code), range: range)]
      case .softBreak: return [Inline(.softBreak, range: range)]
      case .hardBreak: return [Inline(.hardBreak, range: range)]
      case .footnoteReference(let label, let number):
        return [Inline(.footnoteReference(label: label, number: number), range: range)]
      case .link(let destination, let title, let isAutolink):
        guard URLSafety.isSafe(destination) else { return children() }
        let link = Link(destination: destination, title: title, content: children(), isAutolink: isAutolink)
        return [Inline(.link(link), range: range)]
      case .image(let source, let title):
        guard URLSafety.isSafe(source) else { return [] }
        let image = Image(
          source: source, title: title, alt: children().plainText, width: nil, height: nil, sources: [])
        return [Inline(.image(image), range: range)]
      default:
        return children()
      }
    case .html(let name):
      return htmlInlines(name, element, children: children)
    }
  }

  private func htmlInlines(_ name: String, _ element: TreeElement, children: () -> [Inline]) -> [Inline] {
    let range = element.range
    let attributes = element.attributes
    let kind: Inline.Kind
    switch name {
    case "a":
      let anchors = [attributes["id"], attributes["name"]].compactMap { $0 }.filter { !$0.isEmpty }
      let markers = (anchors.first.map { [$0] } ?? []) + anchors.dropFirst().filter { $0 != anchors.first }
      let anchorInlines = markers.map { Inline(.anchor($0), range: range) }
      guard let href = attributes["href"], URLSafety.isSafe(href) else { return anchorInlines + children() }
      let link = Link(destination: href, title: attributes["title"] ?? "", content: children(), isAutolink: false)
      return anchorInlines + [Inline(.link(link), range: range)]
    case "img":
      guard let image = image(attributes) else { return [] }
      kind = .image(image)
    case "picture":
      guard let image = picture(element) else { return [] }
      kind = .image(image)
    case "video":
      guard let video = video(element) else { return [] }
      kind = .image(video)
    case "iframe":
      guard let embed = attributes["src"].flatMap(VideoEmbed.init(source:)) else { return [] }
      kind = .image(
        Image(
          source: embed.poster ?? "", title: "", alt: "Video", width: nil, height: nil, sources: [], video: embed.href))
    case "br": kind = .hardBreak
    case "wbr", "source", "hr": return []
    case "b", "strong": kind = .strong(children())
    case "i", "em", "cite", "dfn", "var": kind = .emphasis(children())
    case "code", "tt", "samp": kind = .code(children().plainText)
    case "kbd": kind = .keyboard(children())
    case "sub": kind = .subscript(children())
    case "sup": kind = .superscript(children())
    case "s", "del", "strike": kind = .strikethrough(children())
    case "ins": kind = .inserted(children())
    case "mark": kind = .marked(children())
    case "small": kind = .small(children())
    case "abbr": kind = .abbreviation(title: attributes["title"] ?? "", content: children())
    default: return children()
    }
    return [Inline(kind, range: range)]
  }

  private func image(_ attributes: [String: String]) -> Image? {
    let source = attributes["src"] ?? ""
    guard URLSafety.isSafe(source) else { return nil }
    return Image(
      source: source, title: attributes["title"] ?? "", alt: attributes["alt"] ?? "",
      width: pixels(attributes["width"]), height: pixels(attributes["height"]), sources: [],
      widthPercent: percent(attributes["width"]), heightPercent: percent(attributes["height"]))
  }

  private func percent(_ value: String?) -> Double? {
    guard let value = value?.trimmingWhitespace(), value.hasSuffix("%"),
      let number = Double(String(value.dropLast()).trimmingWhitespace()), number.isFinite, number > 0
    else { return nil }
    return min(number, 100)
  }

  private func video(_ element: TreeElement) -> Image? {
    let attributes = element.attributes
    let child = childElements(element).first { $0.htmlName == "source" && !($0.attributes["src"] ?? "").isEmpty }
    guard let source = (attributes["src"].flatMap { $0.isEmpty ? nil : $0 }) ?? child?.attributes["src"],
      URLSafety.isSafe(source)
    else { return nil }
    let poster = attributes["poster"].flatMap { URLSafety.isSafe($0) ? $0 : nil } ?? ""
    return Image(
      source: poster, title: attributes["title"] ?? "", alt: "Video", width: pixels(attributes["width"]),
      height: pixels(attributes["height"]), sources: [], video: source)
  }

  private func picture(_ element: TreeElement) -> Image? {
    let descendants = childElements(element)
    let sources = descendants.filter { $0.htmlName == "source" }.compactMap { source -> ImageSource? in
      let candidate = source.attributes["srcset"].flatMap(firstCandidate) ?? source.attributes["src"] ?? ""
      guard !candidate.isEmpty, URLSafety.isSafe(candidate) else { return nil }
      let media = source.attributes["media"] ?? ""
      return ImageSource(source: candidate, media: media, colorScheme: colorScheme(media))
    }
    if var image = descendants.first(where: { $0.htmlName == "img" }).flatMap({ image($0.attributes) }) {
      image.sources = sources
      return image
    }
    guard let first = sources.first else { return nil }
    return Image(source: first.source, title: "", alt: "", width: nil, height: nil, sources: sources)
  }

  private func firstCandidate(_ srcset: String) -> String? {
    srcset.split(separator: ",").first?.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first
      .map(String.init)
  }

  private func colorScheme(_ media: String) -> ColorScheme? {
    let compact = media.lowercased().filter { !$0.isWhitespace }
    if compact.contains("prefers-color-scheme:dark") { return .dark }
    if compact.contains("prefers-color-scheme:light") { return .light }
    return nil
  }

  private func pixels(_ value: String?) -> Int? {
    guard let value = value?.trimmingWhitespace(), !value.hasSuffix("%") else { return nil }
    return Int(String(value.prefix { $0.isASCII && $0.isNumber }))
  }

  private func append(_ inline: Inline, to content: inout [Inline]) {
    if case .text(let addition) = inline.kind, let last = content.last, case .text(let existing) = last.kind {
      content[content.count - 1] = Inline(
        .text(existing + addition), range: SourceRange(start: last.range.start, end: inline.range.end))
    } else {
      content.append(inline)
    }
  }
}

private func normalizedHTMLRun(_ inlines: [Inline]) -> [Inline] {
  var segments: [[Inline]] = [[]]
  var breaks: [Inline] = []
  for inline in inlines {
    if inline.kind == .hardBreak {
      breaks.append(inline)
      segments.append([])
    } else {
      segments[segments.count - 1].append(inline)
    }
  }
  var result: [Inline] = []
  for (index, segment) in segments.enumerated() {
    result += trimmingTrailing(trimmingLeading(segment))
    if index < breaks.count { result.append(breaks[index]) }
  }
  return result
}

private func trimmingLeading(_ inlines: [Inline]) -> [Inline] {
  var result = inlines
  while let first = result.first {
    switch first.kind {
    case .text(let text):
      let trimmed = String(text.drop { $0 == " " })
      if !trimmed.isEmpty {
        result[0].kind = .text(trimmed)
        return result
      }
      result.removeFirst()
    case .softBreak:
      result.removeFirst()
    default:
      if let children = first.children { result[0].kind = first.replacingChildren(trimmingLeading(children)) }
      return result
    }
  }
  return result
}

private func trimmingTrailing(_ inlines: [Inline]) -> [Inline] {
  var result = inlines
  while let last = result.last {
    switch last.kind {
    case .text(var text):
      while text.last == " " { text.removeLast() }
      if !text.isEmpty {
        result[result.count - 1].kind = .text(text)
        return result
      }
      result.removeLast()
    case .softBreak:
      result.removeLast()
    default:
      if let children = last.children {
        result[result.count - 1].kind = last.replacingChildren(trimmingTrailing(children))
      }
      return result
    }
  }
  return result
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

extension Inline {
  fileprivate var isBreak: Bool {
    switch kind {
    case .softBreak, .hardBreak: true
    default: false
    }
  }

  fileprivate var isBlank: Bool {
    switch kind {
    case .softBreak, .hardBreak: true
    case .text(let text): text.allSatisfy { $0 == " " || $0 == "\t" }
    default: false
    }
  }

  fileprivate var children: [Inline]? {
    switch kind {
    case .emphasis(let children), .strong(let children), .strikethrough(let children), .keyboard(let children),
      .subscript(let children), .superscript(let children), .inserted(let children), .marked(let children),
      .small(let children), .abbreviation(_, let children):
      children
    case .link(let link): link.content
    default: nil
    }
  }

  fileprivate func replacingChildren(_ children: [Inline]) -> Kind {
    switch kind {
    case .emphasis: return .emphasis(children)
    case .strong: return .strong(children)
    case .strikethrough: return .strikethrough(children)
    case .keyboard: return .keyboard(children)
    case .subscript: return .subscript(children)
    case .superscript: return .superscript(children)
    case .inserted: return .inserted(children)
    case .marked: return .marked(children)
    case .small: return .small(children)
    case .abbreviation(let title, _): return .abbreviation(title: title, content: children)
    case .link(var link):
      link.content = children
      return .link(link)
    default: return kind
    }
  }
}
