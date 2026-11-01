enum HTMLToken: Hashable {
  case text(String)
  case startTag(name: String, attributes: [String: String], source: String)
  case endTag(name: String, source: String)
  case comment
}

enum HTMLTokenizer {
  private typealias Scalars = [Unicode.Scalar]

  static func tokenize(_ html: String) -> [HTMLToken] {
    let s = Array(html.unicodeScalars)
    var tokens: [HTMLToken] = []
    var text: Scalars = []
    var i = 0
    func flushText() {
      if !text.isEmpty { tokens.append(.text(string(text))) }
      text = []
    }
    while i < s.count {
      if s[i] == "<", let (token, end) = tag(s, at: i) {
        flushText()
        tokens.append(token)
        i = end
      } else {
        text.append(s[i])
        i += 1
      }
    }
    flushText()
    return tokens
  }

  private static func tag(_ s: Scalars, at start: Int) -> (HTMLToken, Int)? {
    var i = start + 1
    if starts(s, "!--", at: i) {
      guard let close = find(s, "-->", from: i + 3) else { return nil }
      return (.comment, close + 3)
    }
    let closing = i < s.count && s[i] == "/"
    if closing { i += 1 }
    guard i < s.count, isASCIILetter(s[i]) else { return nil }
    let nameStart = i
    while i < s.count, isASCIILetter(s[i]) || ("0"..."9").contains(s[i]) || s[i] == "-" { i += 1 }
    let name = string(Array(s[nameStart..<i])).lowercased()
    if closing {
      while i < s.count, isSpace(s[i]) { i += 1 }
      guard i < s.count, s[i] == ">" else { return nil }
      return (.endTag(name: name, source: string(Array(s[start...i]))), i + 1)
    }
    var attributes: [String: String] = [:]
    while true {
      let beforeSpace = i
      while i < s.count, isSpace(s[i]) { i += 1 }
      guard i < s.count else { return nil }
      if s[i] == ">" {
        return (.startTag(name: name, attributes: attributes, source: string(Array(s[start...i]))), i + 1)
      }
      if s[i] == "/", i + 1 < s.count, s[i + 1] == ">" {
        return (.startTag(name: name, attributes: attributes, source: string(Array(s[start...(i + 1)]))), i + 2)
      }
      guard i > beforeSpace else { return nil }
      let attributeStart = i
      while i < s.count, !isSpace(s[i]), !"\"'>/=<".unicodeScalars.contains(s[i]) { i += 1 }
      guard i > attributeStart else { return nil }
      let attribute = string(Array(s[attributeStart..<i])).lowercased()
      var value = ""
      var j = i
      while j < s.count, isSpace(s[j]) { j += 1 }
      if j < s.count, s[j] == "=" {
        j += 1
        while j < s.count, isSpace(s[j]) { j += 1 }
        guard j < s.count else { return nil }
        if s[j] == "\"" || s[j] == "'" {
          guard let close = s[(j + 1)...].firstIndex(of: s[j]) else { return nil }
          value = string(Array(s[(j + 1)..<close]))
          i = close + 1
        } else {
          let valueStart = j
          while j < s.count, !isSpace(s[j]), !"\"'=<>`".unicodeScalars.contains(s[j]) { j += 1 }
          guard j > valueStart else { return nil }
          value = string(Array(s[valueStart..<j]))
          i = j
        }
      }
      if attributes[attribute] == nil { attributes[attribute] = HTMLEntities.decode(value) }
    }
  }

  private static func starts(_ s: Scalars, _ prefix: String, at index: Int) -> Bool {
    let p = Array(prefix.unicodeScalars)
    return index + p.count <= s.count && Array(s[index..<(index + p.count)]) == p
  }

  private static func find(_ s: Scalars, _ needle: String, from start: Int) -> Int? {
    var i = start
    while i < s.count {
      if starts(s, needle, at: i) { return i }
      i += 1
    }
    return nil
  }

  private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
  }

  static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
    scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}"
  }

  static func string(_ scalars: [Unicode.Scalar]) -> String {
    var result = ""
    result.unicodeScalars.append(contentsOf: scalars)
    return result
  }
}

enum HTMLEntities {
  private static let named: [String: Unicode.Scalar] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
  ]

  static func decode(_ text: String) -> String {
    guard text.contains("&") else { return text }
    let s = Array(text.unicodeScalars)
    var result: [Unicode.Scalar] = []
    var i = 0
    while i < s.count {
      if s[i] == "&", let semicolon = s[(i + 1)...].prefix(10).firstIndex(of: ";"),
        let scalar = entity(HTMLTokenizer.string(Array(s[(i + 1)..<semicolon])))
      {
        result.append(scalar)
        i = semicolon + 1
      } else {
        result.append(s[i])
        i += 1
      }
    }
    return HTMLTokenizer.string(result)
  }

  private static func entity(_ name: String) -> Unicode.Scalar? {
    if let scalar = named[name] { return scalar }
    guard name.hasPrefix("#") else { return nil }
    let digits = name.dropFirst()
    let value: UInt32?
    if digits.first == "x" || digits.first == "X" {
      value = UInt32(digits.dropFirst(), radix: 16)
    } else {
      value = UInt32(digits, radix: 10)
    }
    guard let value, !digits.isEmpty else { return nil }
    guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
    return scalar
  }
}

struct InlineBuilder {
  private struct Frame {
    var name: String
    var attributes: [String: String]
    var start: SourcePosition
    var content: [Inline] = []
  }

  private static let containers: Set<String> = ["kbd", "sub", "sup", "b", "strong", "i", "em", "code", "a"]
  private static let transparent: Set<String> = ["details", "summary"]

  private var root: [Inline] = []
  private var frames: [Frame] = []

  var isEmpty: Bool { root.isEmpty && frames.isEmpty }

  mutating func append(_ inline: Inline) {
    if frames.isEmpty {
      Self.append(inline, to: &root)
    } else {
      Self.append(inline, to: &frames[frames.count - 1].content)
    }
  }

  mutating func handle(_ token: HTMLToken, range: SourceRange, decodingText: Bool) {
    switch token {
    case .text(let text):
      append(Inline(.text(decodingText ? HTMLEntities.decode(text) : text), range: range))
    case .comment:
      break
    case .startTag(let name, let attributes, let source):
      if name == "br" {
        append(Inline(.hardBreak, range: range))
      } else if name == "img" {
        append(Inline(.image(Self.image(attributes)), range: range))
      } else if Self.containers.contains(name) {
        frames.append(Frame(name: name, attributes: attributes, start: range.start))
      } else if !Self.transparent.contains(name) {
        append(Inline(.text(source), range: range))
      }
    case .endTag(let name, let source):
      if Self.containers.contains(name) {
        guard let index = frames.lastIndex(where: { $0.name == name }) else { return }
        while frames.count > index { closeFrame(end: range.end) }
      } else if !Self.transparent.contains(name) && name != "br" && name != "img" {
        append(Inline(.text(source), range: range))
      }
    }
  }

  mutating func finish(end: SourcePosition) -> [Inline] {
    while !frames.isEmpty { closeFrame(end: end) }
    return root
  }

  private mutating func closeFrame(end: SourcePosition) {
    let frame = frames.removeLast()
    let range = SourceRange(start: frame.start, end: end)
    let kind: Inline.Kind?
    switch frame.name {
    case "kbd": kind = .keyboard(frame.content)
    case "sub": kind = .subscript(frame.content)
    case "sup": kind = .superscript(frame.content)
    case "b", "strong": kind = .strong(frame.content)
    case "i", "em": kind = .emphasis(frame.content)
    case "code": kind = .code(frame.content.plainText)
    default:
      if let href = frame.attributes["href"] {
        kind = .link(
          Link(destination: href, title: frame.attributes["title"] ?? "", content: frame.content, isAutolink: false))
      } else {
        kind = nil
      }
    }
    if let kind {
      append(Inline(kind, range: range))
    } else {
      for inline in frame.content { append(inline) }
    }
  }

  private static func image(_ attributes: [String: String]) -> Image {
    Image(
      source: attributes["src"] ?? "", title: attributes["title"] ?? "", alt: attributes["alt"] ?? "",
      width: attributes["width"].flatMap { Int($0) }, height: attributes["height"].flatMap { Int($0) })
  }

  private static func append(_ inline: Inline, to content: inout [Inline]) {
    if case .text(let addition) = inline.kind, let last = content.last, case .text(let existing) = last.kind {
      content[content.count - 1] = Inline(
        .text(existing + addition), range: SourceRange(start: last.range.start, end: inline.range.end))
    } else {
      content.append(inline)
    }
  }
}
