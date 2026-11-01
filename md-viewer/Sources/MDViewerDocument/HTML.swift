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
  private static let maximumTagLength = 2048

  static func tokenize(_ html: String) -> [HTMLToken] {
    let s = Array(html.unicodeScalars)
    var nextGreaterThan = [Int](repeating: s.count, count: s.count + 1)
    for index in stride(from: s.count - 1, through: 0, by: -1) {
      nextGreaterThan[index] = s[index] == ">" ? index : nextGreaterThan[index + 1]
    }
    var tokens: [HTMLToken] = []
    var text: Scalars = []
    var rawTextSearches: [String: (from: Int, end: Int?)] = [:]
    var i = 0
    func flushText() {
      if !text.isEmpty { tokens.append(.text(string(text))) }
      text = []
    }
    while i < s.count {
      guard s[i] == "<", let (token, end) = tag(s, at: i, nextGreaterThan: nextGreaterThan) else {
        text.append(s[i])
        i += 1
        continue
      }
      flushText()
      tokens.append(token)
      i = end
      guard case .startTag(let name, _) = token, rawTextElements.contains(name) else { continue }
      let close: Int?
      if let cached = rawTextSearches[name], i >= cached.from, cached.end.map({ i <= $0 }) ?? true {
        close = cached.end
      } else {
        close = rawTextEnd(s, name, from: i)
        rawTextSearches[name] = (i, close)
      }
      if let close {
        text = Scalars(s[i..<close])
        flushText()
        i = close
      }
    }
    flushText()
    return tokens
  }

  private static func rawTextEnd(_ s: Scalars, _ name: String, from start: Int) -> Int? {
    let needle = Array(("</" + name).unicodeScalars)
    var i = start
    while i + needle.count <= s.count {
      if matchesIgnoringASCIICase(s, needle, at: i) {
        let after = i + needle.count
        if after == s.count || isSpace(s[after]) || s[after] == ">" || s[after] == "/" { return i }
      }
      i += 1
    }
    return nil
  }

  private static func tag(_ s: Scalars, at start: Int, nextGreaterThan: [Int]) -> (HTMLToken, Int)? {
    var i = start + 1
    guard i < s.count else { return nil }
    if matches(s, "!--", at: i) {
      guard let close = find(s, "-->", from: i + 3) else { return (.comment, s.count) }
      return (.comment, close + 3)
    }
    if s[i] == "!" || s[i] == "?" {
      return (.comment, min(nextGreaterThan[i] + 1, s.count))
    }
    guard nextGreaterThan[i] < s.count else { return nil }
    let limit = min(s.count, start + maximumTagLength)
    let closing = s[i] == "/"
    if closing { i += 1 }
    guard i < limit, isASCIILetter(s[i]) else { return nil }
    let nameStart = i
    while i < limit, isASCIILetter(s[i]) || ("0"..."9").contains(s[i]) || s[i] == "-" { i += 1 }
    let name = string(Array(s[nameStart..<i])).lowercased()
    if closing {
      while i < limit, isSpace(s[i]) { i += 1 }
      guard i < limit, s[i] == ">" else { return nil }
      return (.endTag(name: name), i + 1)
    }
    var attributes: [String: String] = [:]
    while true {
      let beforeSpace = i
      while i < limit, isSpace(s[i]) { i += 1 }
      guard i < limit else { return nil }
      if s[i] == ">" { return (.startTag(name: name, attributes: attributes), i + 1) }
      if s[i] == "/", i + 1 < limit, s[i + 1] == ">" { return (.startTag(name: name, attributes: attributes), i + 2) }
      guard i > beforeSpace else { return nil }
      let attributeStart = i
      while i < limit, !isSpace(s[i]), !"\"'>/=<".unicodeScalars.contains(s[i]) { i += 1 }
      guard i > attributeStart else { return nil }
      let attribute = string(Array(s[attributeStart..<i])).lowercased()
      var value = ""
      var j = i
      while j < limit, isSpace(s[j]) { j += 1 }
      if j < limit, s[j] == "=" {
        j += 1
        while j < limit, isSpace(s[j]) { j += 1 }
        guard j < limit else { return nil }
        if s[j] == "\"" || s[j] == "'" {
          guard let close = s[(j + 1)..<limit].firstIndex(of: s[j]) else { return nil }
          value = string(Array(s[(j + 1)..<close]))
          i = close + 1
        } else {
          let valueStart = j
          while j < limit, !isSpace(s[j]), !"\"'=<>`".unicodeScalars.contains(s[j]) { j += 1 }
          guard j > valueStart else { return nil }
          value = string(Array(s[valueStart..<j]))
          i = j
        }
      }
      if attributes[attribute] == nil { attributes[attribute] = HTMLEntities.decode(value) }
    }
  }

  private static func matches(_ s: Scalars, _ needle: String, at index: Int) -> Bool {
    var i = index
    for scalar in needle.unicodeScalars {
      guard i < s.count, s[i] == scalar else { return false }
      i += 1
    }
    return true
  }

  private static func matchesIgnoringASCIICase(_ s: Scalars, _ needle: [Unicode.Scalar], at index: Int) -> Bool {
    for (offset, scalar) in needle.enumerated() {
      let candidate = s[index + offset]
      let lowered = ("A"..."Z").contains(candidate) ? Unicode.Scalar(candidate.value + 32)! : candidate
      if lowered != scalar { return false }
    }
    return true
  }

  private static func find(_ s: Scalars, _ needle: String, from start: Int) -> Int? {
    var i = start
    while i < s.count {
      if matches(s, needle, at: i) { return i }
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
  private static let maximumNameLength = 32

  static func decode(_ text: String) -> String {
    guard text.contains("&") else { return text }
    let s = Array(text.unicodeScalars)
    var result = ""
    var i = 0
    while i < s.count {
      guard s[i] == "&", let (decoded, end) = reference(s, at: i) else {
        result.unicodeScalars.append(s[i])
        i += 1
        continue
      }
      result += decoded
      i = end
    }
    return result
  }

  private static func reference(_ s: [Unicode.Scalar], at start: Int) -> (String, Int)? {
    var i = start + 1
    guard i < s.count else { return nil }
    if s[i] == "#" {
      i += 1
      var radix: UInt32 = 10
      if i < s.count, s[i] == "x" || s[i] == "X" {
        radix = 16
        i += 1
      }
      let digitsStart = i
      var value: UInt32 = 0
      while i < s.count, let digit = digitValue(s[i]), digit < radix {
        value = min(value * radix + digit, 0x110000)
        i += 1
      }
      guard i > digitsStart else { return nil }
      if i < s.count, s[i] == ";" { i += 1 }
      let scalar = value == 0 ? nil : Unicode.Scalar(value)
      return (String(scalar ?? "\u{FFFD}"), i)
    }
    let nameStart = i
    while i < s.count, i - nameStart < maximumNameLength, isASCIILetterOrDigit(s[i]) {
      i += 1
    }
    guard i > nameStart, i < s.count, s[i] == ";",
      let value = HTMLEntityTable.entities[HTMLTokenizer.string(Array(s[nameStart..<i]))]
    else { return nil }
    return (value, i + 1)
  }

  private static func digitValue(_ scalar: Unicode.Scalar) -> UInt32? {
    switch scalar {
    case "0"..."9": scalar.value - 48
    case "a"..."f": scalar.value - 87
    case "A"..."F": scalar.value - 55
    default: nil
    }
  }

  private static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
  }
}

enum URLSafety {
  private static let blockedSchemes: Set<String> = ["javascript", "vbscript", "data"]

  static func isSafe(_ url: String) -> Bool {
    let compact = HTMLEntities.decode(url).unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }
    guard let colon = compact.firstIndex(of: ":") else { return true }
    let scheme = HTMLTokenizer.string(Array(compact[..<colon])).lowercased()
    if scheme.contains("/") || scheme.contains("?") || scheme.contains("#") { return true }
    return !blockedSchemes.contains(scheme)
  }
}
