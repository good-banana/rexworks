public struct FrontMatterSplit: Hashable, Sendable {
  public var entries: [FrontMatterEntry]
  public var body: String
  public var bodyLineOffset: Int
}

public enum FrontMatter {
  private typealias Scalars = [Unicode.Scalar]

  public static func split(_ markdown: String) -> FrontMatterSplit {
    let unchanged = FrontMatterSplit(entries: [], body: markdown, bodyLineOffset: 0)
    let scalars = Array(markdown.unicodeScalars)
    guard let (content, matchEnd) = delimitedBlock(scalars) else { return unchanged }
    var entries: [(key: String, lines: [Scalars])] = []
    for line in splitLines(content) {
      if line.allSatisfy(isWhitespace) || line.drop(while: isWhitespace).first == "#" { continue }
      if let (key, value) = field(line) {
        entries.append((key, value.isEmpty ? [] : [value]))
      } else if !entries.isEmpty, let first = line.first, isWhitespace(first) {
        entries[entries.count - 1].lines.append(line)
      } else {
        return unchanged
      }
    }
    if entries.isEmpty && !content.allSatisfy(isWhitespace) { return unchanged }
    let result = entries.map { entry in
      let nested = entry.lines.filter { $0.first.map(isWhitespace) ?? false }
      let strip = nested.map { $0.prefix(while: isWhitespace).count }.min() ?? 0
      let lines = entry.lines.map { line in
        (line.first.map(isWhitespace) ?? false) ? Scalars(line.dropFirst(strip)) : line
      }
      return FrontMatterEntry(key: entry.key, value: lines.map(string).joined(separator: "\n"))
    }
    let consumed = scalars[..<matchEnd]
    return FrontMatterSplit(
      entries: result, body: string(Scalars(scalars[matchEnd...])), bodyLineOffset: lineEndings(consumed))
  }

  private static func delimitedBlock(_ s: Scalars) -> (content: Scalars, end: Int)? {
    var i = s.first == "\u{FEFF}" ? 1 : 0
    guard hasPrefix(s, "---", at: i) else { return nil }
    i += 3
    while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
    if i < s.count, s[i] == "\r" { i += 1 }
    guard i < s.count, s[i] == "\n" else { return nil }
    i += 1
    let contentStart = i
    while true {
      if let end = closingLineEnd(s, at: i) { return (Scalars(s[contentStart..<i]), end) }
      guard let newline = s[i...].firstIndex(of: "\n") else { return nil }
      i = newline + 1
    }
  }

  private static func closingLineEnd(_ s: Scalars, at start: Int) -> Int? {
    guard hasPrefix(s, "---", at: start) || hasPrefix(s, "...", at: start) else { return nil }
    var i = start + 3
    while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
    if i == s.count { return i }
    if s[i] == "\n" { return i + 1 }
    if s[i] == "\r", i + 1 < s.count, s[i + 1] == "\n" { return i + 2 }
    return nil
  }

  private static func field(_ line: Scalars) -> (key: String, value: Scalars)? {
    guard let first = line.first, !isWhitespace(first), first != "#", first != ":", first != "-",
      let colon = line.firstIndex(of: ":")
    else { return nil }
    let rest = line[(colon + 1)...]
    let value = rest.drop(while: isWhitespace)
    if !value.isEmpty && (rest.first.map { !isWhitespace($0) } ?? true || value.contains(where: isLineTerminator)) {
      return nil
    }
    return (trim(Scalars(line[..<colon])), Array(trimmed(Scalars(value))))
  }

  private static func splitLines(_ content: Scalars) -> [Scalars] {
    var lines: [Scalars] = []
    var current: Scalars = []
    for scalar in content {
      if scalar == "\n" {
        if current.last == "\r" { current.removeLast() }
        lines.append(current)
        current = []
      } else {
        current.append(scalar)
      }
    }
    lines.append(current)
    return lines
  }

  private static func lineEndings(_ scalars: ArraySlice<Unicode.Scalar>) -> Int {
    var count = 0
    var previous: Unicode.Scalar?
    for scalar in scalars {
      if scalar == "\r" || (scalar == "\n" && previous != "\r") { count += 1 }
      previous = scalar
    }
    return count
  }

  private static func hasPrefix(_ s: Scalars, _ prefix: String, at index: Int) -> Bool {
    let p = Array(prefix.unicodeScalars)
    return index + p.count <= s.count && Array(s[index..<(index + p.count)]) == p
  }

  private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
    default: false
    }
  }

  private static func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
    scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}"
  }

  private static func trimmed(_ s: Scalars) -> ArraySlice<Unicode.Scalar> {
    guard let start = s.firstIndex(where: { !isWhitespace($0) }), let end = s.lastIndex(where: { !isWhitespace($0) })
    else { return [] }
    return s[start...end]
  }

  private static func trim(_ s: Scalars) -> String { string(Scalars(trimmed(s))) }

  private static func string(_ s: Scalars) -> String {
    var result = ""
    result.unicodeScalars.append(contentsOf: s)
    return result
  }
}
