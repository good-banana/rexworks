enum HTMLToken: Hashable {
  case text(String)
  case startTag(name: String, attributes: [String: String])
  case endTag(name: String)
  case comment
}

enum HTMLTokenizer {
  private typealias Scalars = [Unicode.Scalar]

  static let rawTextElements: Set<String> = [
    "script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "noscript", "plaintext",
  ]

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
      guard s[i] == "<", let (token, end) = tag(s, at: i) else {
        text.append(s[i])
        i += 1
        continue
      }
      flushText()
      tokens.append(token)
      i = end
      if case .startTag(let name, _) = token, rawTextElements.contains(name) {
        let close = rawTextEnd(s, name: name, from: i) ?? s.count
        text = Scalars(s[i..<close])
        flushText()
        i = close
      }
    }
    flushText()
    return tokens
  }

  private static func rawTextEnd(_ s: Scalars, name: String, from start: Int) -> Int? {
    let needle = Array(("</" + name).unicodeScalars)
    var i = start
    while i + needle.count <= s.count {
      let candidate = string(Array(s[i..<(i + needle.count)])).lowercased()
      if candidate.unicodeScalars.elementsEqual(needle) {
        let after = i + needle.count
        if after == s.count || isSpace(s[after]) || s[after] == ">" || s[after] == "/" { return i }
      }
      i += 1
    }
    return nil
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
      return (.endTag(name: name), i + 1)
    }
    var attributes: [String: String] = [:]
    while true {
      let beforeSpace = i
      while i < s.count, isSpace(s[i]) { i += 1 }
      guard i < s.count else { return nil }
      if s[i] == ">" {
        return (.startTag(name: name, attributes: attributes), i + 1)
      }
      if s[i] == "/", i + 1 < s.count, s[i + 1] == ">" {
        return (.startTag(name: name, attributes: attributes), i + 2)
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

enum URLSafety {
  private static let blockedSchemes: Set<String> = ["javascript", "vbscript", "data"]

  static func isSafe(_ url: String) -> Bool {
    let compact = url.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }
    guard let colon = compact.firstIndex(of: ":") else { return true }
    let scheme = HTMLTokenizer.string(Array(compact[..<colon])).lowercased()
    if scheme.contains("/") || scheme.contains("?") || scheme.contains("#") { return true }
    return !blockedSchemes.contains(scheme)
  }
}
