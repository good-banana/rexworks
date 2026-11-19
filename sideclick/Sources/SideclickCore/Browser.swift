import Foundation

public struct BuiltInBrowser: Equatable, Sendable {
  public let name: String
  public let executable: String
  public let installArguments: [String]
  public let website: String

  public static let terminalBrowser = BuiltInBrowser(
    name: "terminal-browser", executable: "terminal-browser",
    installArguments: ["install", "--cask", "terminal-browser"], website: "https://terminal-browser.com")
  public static let w3m = BuiltInBrowser(
    name: "w3m", executable: "w3m", installArguments: ["install", "w3m"], website: "https://w3m.sourceforge.net")
  public static let lynx = BuiltInBrowser(
    name: "lynx", executable: "lynx", installArguments: ["install", "lynx"],
    website: "https://lynx.invisible-island.net")

  public static let all = [terminalBrowser, w3m, lynx]

  public static func named(_ name: String) -> BuiltInBrowser? {
    all.first { $0.name == name }
  }

  public var installCommand: String {
    (["brew"] + installArguments).joined(separator: " ")
  }
}

public let urlPlaceholder = "{url}"

public enum BrowserChoice: Equatable, Sendable {
  case builtIn(BuiltInBrowser)
  case custom(command: String)

  public static let `default` = BrowserChoice.builtIn(.terminalBrowser)

  public var label: String {
    switch self {
    case .builtIn(let browser): browser.name
    case .custom: "custom"
    }
  }

  public var description: String {
    switch self {
    case .builtIn(let browser): browser.name
    case .custom(let command): "custom: \(command)"
    }
  }

  public static func parse(_ arguments: [String]) -> Result<BrowserChoice, OpenError> {
    let names = BuiltInBrowser.all.map(\.name).joined(separator: ", ")
    switch arguments.count {
    case 1:
      guard let browser = BuiltInBrowser.named(arguments[0]) else {
        return .failure(OpenError("unknown browser \(arguments[0]); choose \(names), or custom '<command with {url}>'"))
      }
      return .success(.builtIn(browser))
    case 2 where arguments[0] == "custom":
      let command = arguments[1].trimmingCharacters(in: .whitespaces)
      guard command.contains(urlPlaceholder) else {
        return .failure(OpenError("a custom command must contain \(urlPlaceholder) where the link goes"))
      }
      return .success(.custom(command: command))
    default:
      return .failure(OpenError("usage: sideclick config set browser <\(names)> | custom '<command with {url}>'"))
    }
  }
}

extension BrowserChoice: Codable {
  private enum CodingKeys: String, CodingKey {
    case name
    case command
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let name = try container.decode(String.self, forKey: .name)
    if name == "custom" {
      self = .custom(command: try container.decode(String.self, forKey: .command))
    } else if let browser = BuiltInBrowser.named(name) {
      self = .builtIn(browser)
    } else {
      throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "unknown browser \(name)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(label, forKey: .name)
    if case .custom(let command) = self { try container.encode(command, forKey: .command) }
  }
}

public func customShellScript(_ command: String) -> String {
  ["'\(urlPlaceholder)'", "\"\(urlPlaceholder)\"", urlPlaceholder].reduce(command) {
    $0.replacingOccurrences(of: $1, with: "\"$1\"")
  }
}

public func findBrowserExecutable(_ name: String, path: String?) -> String? {
  findExecutable(name, path: [path, "/opt/homebrew/bin", "/usr/local/bin"].compactMap { $0 }.joined(separator: ":"))
}

public struct AvailabilityCheck {
  public var find: (String) -> String?
  public var interactive: Bool
  public var ask: (String) -> Bool
  public var runBrew: (String, [String]) -> Int32
  public var say: (String) -> Void

  public init(
    find: @escaping (String) -> String?, interactive: Bool, ask: @escaping (String) -> Bool,
    runBrew: @escaping (String, [String]) -> Int32, say: @escaping (String) -> Void
  ) {
    self.find = find
    self.interactive = interactive
    self.ask = ask
    self.runBrew = runBrew
    self.say = say
  }

  public func ensure(_ browser: BuiltInBrowser) -> Result<String, OpenError> {
    if let path = find(browser.executable) { return .success(path) }
    let rerun = "then rerun this command"
    guard let brew = find("brew") else {
      return .failure(
        OpenError(
          "\(browser.name) isn't installed and Homebrew isn't available; install it from \(browser.website), \(rerun)"))
    }
    guard interactive else {
      return .failure(
        OpenError("\(browser.name) isn't installed; install it with `\(browser.installCommand)`, \(rerun)"))
    }
    guard ask("\(browser.name) isn't installed. Install it with Homebrew (\(browser.installCommand))? [y/N] ") else {
      return .failure(OpenError("\(browser.name) is needed; install it with `\(browser.installCommand)`, \(rerun)"))
    }
    let status = runBrew(brew, browser.installArguments)
    guard status == 0, let path = find(browser.executable) else {
      return .failure(OpenError("installing \(browser.name) didn't succeed (brew exited with \(status)); \(rerun)"))
    }
    say("installed \(browser.name) at \(path)")
    return .success(path)
  }
}

public func isYes(_ answer: String?) -> Bool {
  ["y", "yes"].contains(answer?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
}

public func bundledAppCandidates(executable: URL, appName: String = "Sideclick.app") -> [URL] {
  let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
  return ["../libexec", "../app"].map {
    directory.appendingPathComponent($0, isDirectory: true).appendingPathComponent(appName, isDirectory: true)
      .standardizedFileURL
  }
}

public func installedByHomebrew(executable: URL) -> Bool {
  let components = executable.resolvingSymlinksInPath().pathComponents
  guard let cellar = components.lastIndex(of: "Cellar"), cellar + 1 < components.count else { return false }
  return components[cellar + 1] == "sideclick"
}
