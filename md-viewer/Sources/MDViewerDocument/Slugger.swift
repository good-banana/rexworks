struct Slugger {
  private var occurrences: [String: Int] = [:]

  static func slugify(_ text: String) -> String {
    var result = ""
    for scalar in text.trimmingWhitespace().lowercased().unicodeScalars {
      if scalar == " " {
        result.append("-")
      } else if scalar == "-" || isKept(scalar) {
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  mutating func slug(_ text: String) -> String {
    let base = Self.slugify(text)
    var result = base
    while occurrences[result] != nil {
      occurrences[base, default: 0] += 1
      result = "\(base)-\(occurrences[base] ?? 0)"
    }
    occurrences[result] = 0
    return result
  }

  private static func isKept(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
      .nonspacingMark, .spacingMark, .enclosingMark,
      .decimalNumber, .letterNumber, .otherNumber,
      .connectorPunctuation:
      true
    default:
      false
    }
  }
}

extension String {
  func trimmingWhitespace() -> String {
    let scalars = Array(unicodeScalars)
    guard let start = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
      let end = scalars.lastIndex(where: { !$0.properties.isWhitespace })
    else { return "" }
    var result = ""
    result.unicodeScalars.append(contentsOf: scalars[start...end])
    return result
  }
}
