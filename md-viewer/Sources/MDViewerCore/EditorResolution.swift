import Foundation

public struct LoginEnvironment: Equatable, Sendable {
  public let variables: [String: String]
  public let notice: String?

  public init(variables: [String: String], notice: String? = nil) {
    self.variables = variables
    self.notice = notice
  }

  public static let probeTimeout: TimeInterval = 3
  public static let fallbackNotice = "Could not read your login environment; using md-viewer's own"

  public static func probe(
    runner: ProcessRunning, ownEnvironment: [String: String], isExecutable: (String) -> Bool
  ) -> LoginEnvironment {
    let shell = ownEnvironment["SHELL"].flatMap { isExecutable($0) ? $0 : nil } ?? "/bin/zsh"
    if let result = try? runner.run(shell, ["-l", "-c", "/usr/bin/env -0"], timeout: probeTimeout),
      result.status == 0
    {
      let variables = parse(result.stdout)
      if !variables.isEmpty { return LoginEnvironment(variables: variables) }
    }
    return LoginEnvironment(variables: ownEnvironment, notice: fallbackNotice)
  }

  public static func parse(_ data: Data) -> [String: String] {
    var variables: [String: String] = [:]
    var records = data.split(separator: 0, omittingEmptySubsequences: false).map {
      String(decoding: $0, as: UTF8.self)
    }
    if let first = records.first, let newline = first.lastIndex(of: "\n") {
      records[0] = String(first[first.index(after: newline)...])
    }
    for record in records {
      guard let equals = record.firstIndex(of: "="), isVariableName(record[..<equals]) else { continue }
      variables[String(record[..<equals])] = String(record[record.index(after: equals)...])
    }
    return variables
  }

  private static func isVariableName(_ name: Substring) -> Bool {
    guard let first = name.unicodeScalars.first, first == "_" || isASCIILetter(first) else { return false }
    return name.unicodeScalars.allSatisfy { $0 == "_" || isASCIILetter($0) || ("0"..."9").contains($0) }
  }

  private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
  }
}

public enum ShellWords {
  public static func split(_ text: String) -> [String]? {
    var words: [String] = []
    var current = ""
    var inWord = false
    var quote: Character?
    var escaped = false
    for character in text {
      if escaped {
        current.append(character)
        escaped = false
      } else if quote == "'" {
        if character == "'" { quote = nil } else { current.append(character) }
      } else if character == "\\" {
        escaped = true
        inWord = true
      } else if quote == "\"" {
        if character == "\"" { quote = nil } else { current.append(character) }
      } else if character == "'" || character == "\"" {
        quote = character
        inWord = true
      } else if character == " " || character == "\t" || character == "\n" {
        if inWord { words.append(current) }
        current = ""
        inWord = false
      } else {
        current.append(character)
        inWord = true
      }
    }
    if escaped || quote != nil { return nil }
    if inWord { words.append(current) }
    return words
  }
}

public enum EditorSource: Equatable, Sendable {
  case setting
  case ownEnvironment(String)
  case loginEnvironment(String)
}

extension EditorSource {
  public var label: String {
    switch self {
    case .setting: "setting"
    case .ownEnvironment(let name): "$\(name)"
    case .loginEnvironment(let name): "$\(name) from your login shell"
    }
  }
}

public struct ResolvedEditor: Equatable, Sendable {
  public let executable: String
  public let words: [String]
  public let kind: EditorKind
  public let source: EditorSource

  public var profile: EditorProfile { EditorProfile(kind: kind) }
}

public struct EditorCandidate: Equatable, Sendable {
  public let name: String
  public let executable: String
  public let kind: EditorKind
}

public struct EditorResolution: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case resolved(ResolvedEditor)
    case stopped(String)
    case needsPicker
  }

  public let outcome: Outcome
  public let notices: [String]
}

public struct EditorResolver {
  public static let candidateNames = [
    "nvim", "hx", "vim", "emacs", "nano", "micro", "kak", "code", "cursor", "zed", "subl",
  ]

  public let settings: Settings
  public let ownEnvironment: [String: String]
  public let loginEnvironment: () -> LoginEnvironment
  public let isExecutable: (String) -> Bool

  public init(
    settings: Settings, ownEnvironment: [String: String], loginEnvironment: @escaping () -> LoginEnvironment,
    isExecutable: @escaping (String) -> Bool
  ) {
    self.settings = settings
    self.ownEnvironment = ownEnvironment
    self.loginEnvironment = loginEnvironment
    self.isExecutable = isExecutable
  }

  public func resolve() -> EditorResolution {
    var skipped: [String] = []
    var login: LoginEnvironment?
    func loginValue() -> LoginEnvironment {
      if let login { return login }
      let value = loginEnvironment()
      login = value
      return value
    }
    func finish(_ outcome: EditorResolution.Outcome) -> EditorResolution {
      EditorResolution(outcome: outcome, notices: (login?.notice.map { [$0] } ?? []) + skipped)
    }

    if let setting = settings.editor {
      if let editor = editor(from: setting, kind: settings.editorKind, source: .setting, login: loginValue()) {
        return finish(.resolved(editor))
      }
      let name = ShellWords.split(setting)?.first ?? setting
      return finish(.stopped("editor setting: \(name) not found; , to choose"))
    }

    for name in ["VISUAL", "EDITOR"] {
      let source = EditorSource.ownEnvironment(name)
      if let editor = fromEnvironment(ownEnvironment, name, source, loginValue(), &skipped) {
        return finish(.resolved(editor))
      }
    }
    for name in ["VISUAL", "EDITOR"] {
      let source = EditorSource.loginEnvironment(name)
      if let editor = fromEnvironment(loginValue().variables, name, source, loginValue(), &skipped) {
        return finish(.resolved(editor))
      }
    }
    return finish(.needsPicker)
  }

  public func candidates() -> [EditorCandidate] {
    let directories = Self.pathDirectories(loginEnvironment().variables["PATH"])
    return Self.candidateNames.compactMap { name in
      guard let path = directories.map({ "\($0)/\(name)" }).first(where: isExecutable) else { return nil }
      return EditorCandidate(name: name, executable: path, kind: EditorProfile.detectKind(executable: path))
    }
  }

  private func fromEnvironment(
    _ environment: [String: String], _ name: String, _ source: EditorSource, _ login: LoginEnvironment,
    _ skipped: inout [String]
  ) -> ResolvedEditor? {
    guard let value = environment[name], !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    if let editor = editor(from: value, kind: nil, source: source, login: login) { return editor }
    let first = ShellWords.split(value)?.first ?? value
    let notice = "$\(name) names \(first), which is not installed"
    if !skipped.contains(notice) { skipped.append(notice) }
    return nil
  }

  private func editor(
    from value: String, kind: EditorKind?, source: EditorSource, login: LoginEnvironment
  ) -> ResolvedEditor? {
    guard let words = ShellWords.split(value), let first = words.first,
      let executable = locate(first, login: login)
    else { return nil }
    return ResolvedEditor(
      executable: executable, words: Array(words.dropFirst()),
      kind: kind ?? EditorProfile.detectKind(executable: first), source: source)
  }

  private func locate(_ word: String, login: LoginEnvironment) -> String? {
    if word.contains("/") { return word.hasPrefix("/") && isExecutable(word) ? word : nil }
    let directories =
      Self.pathDirectories(login.variables["PATH"]) + Self.pathDirectories(ownEnvironment["PATH"])
    return directories.map { "\($0)/\(word)" }.first(where: isExecutable)
  }

  private static func pathDirectories(_ path: String?) -> [String] {
    (path ?? "").split(separator: ":").map(String.init)
  }
}
