public enum SyntaxToken: String, CaseIterable, Hashable, Sendable {
  case keyword, string, number, comment, function, type, variable, operatorSymbol, punctuation, metaTag, attribute
}

public struct TokenSpan: Hashable, Sendable {
  public var range: Range<Int>
  public var token: SyntaxToken

  public init(range: Range<Int>, token: SyntaxToken) {
    self.range = range
    self.token = token
  }
}

enum SyntaxScopes {
  private enum Mapping {
    case token(SyntaxToken)
    case plain
  }

  private static let table: [String: Mapping] = {
    var table: [String: Mapping] = [:]
    func assign(_ token: SyntaxToken, _ scopes: [String]) {
      for scope in scopes { table[scope] = .token(token) }
    }
    assign(.keyword, ["keyword", "doctag", "template-tag", "variable.language", "meta.keyword"])
    assign(.string, ["string", "regexp", "char.escape", "addition", "meta.string"])
    assign(.number, ["number", "literal"])
    assign(.comment, ["comment", "quote"])
    assign(.function, ["title", "title.function", "section", "function"])
    assign(.type, ["type", "title.class", "class", "built_in"])
    assign(.variable, ["variable", "template-variable", "symbol", "deletion", "variable.constant"])
    assign(.operatorSymbol, ["operator"])
    assign(.punctuation, ["punctuation"])
    assign(
      .metaTag, ["meta", "tag", "name", "selector-tag", "selector-id", "selector-class", "selector-pseudo", "bullet"])
    assign(.attribute, ["attr", "attribute", "property", "selector-attr"])
    for scope in ["subst", "params", "emphasis", "strong", "link", "code", "formula"] { table[scope] = .plain }
    return table
  }()

  private static func mapping(forClasses classes: String) -> Mapping? {
    let names = classes.split(separator: " ").map(String.init)
    guard let first = names.first, first.hasPrefix("hljs-") else { return nil }
    var parts = [String(first.dropFirst(5))]
    parts += names.dropFirst().map { name in
      var trimmed = Substring(name)
      while trimmed.hasSuffix("_") { trimmed = trimmed.dropLast() }
      return String(trimmed)
    }
    while !parts.isEmpty {
      if let mapping = table[parts.joined(separator: ".")] { return mapping }
      parts.removeLast()
    }
    return nil
  }

  static func token(forScopeChain chain: [String]) -> SyntaxToken? {
    for classes in chain.reversed() {
      switch mapping(forClasses: classes) {
      case .token(let token): return token
      case .plain: return nil
      case nil: continue
      }
    }
    return nil
  }
}
