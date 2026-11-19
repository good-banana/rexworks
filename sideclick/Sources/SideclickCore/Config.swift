import Foundation

public struct SupportPaths: Sendable {
  public let root: URL
  public let configFile: URL
  public let handlerLog: URL
  public let app: URL

  public init(home: URL) {
    root = home.appendingPathComponent("Library/Application Support/sideclick", isDirectory: true)
    configFile = root.appendingPathComponent("config.json")
    handlerLog = root.appendingPathComponent("handler.log")
    app = home.appendingPathComponent("Applications/Sideclick.app", isDirectory: true)
  }
}

public struct Config: Codable, Equatable, Sendable {
  public var rexPath: String
  public var browser: BrowserChoice
  public var browserPath: String?
  public var previousHandlers: [String: String]

  public init(
    rexPath: String, browser: BrowserChoice = .default, browserPath: String?, previousHandlers: [String: String]
  ) {
    self.rexPath = rexPath
    self.browser = browser
    self.browserPath = browserPath
    self.previousHandlers = previousHandlers
  }

  private enum CodingKeys: String, CodingKey {
    case rexPath
    case browser
    case browserPath
    case previousHandlers
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rexPath = try container.decode(String.self, forKey: .rexPath)
    browser = try container.decodeIfPresent(BrowserChoice.self, forKey: .browser) ?? .default
    browserPath = try container.decodeIfPresent(String.self, forKey: .browserPath)
    previousHandlers = try container.decodeIfPresent([String: String].self, forKey: .previousHandlers) ?? [:]
  }
}

public enum ConfigStore {
  public static func load(_ paths: SupportPaths) throws -> Config? {
    guard FileManager.default.fileExists(atPath: paths.configFile.path) else { return nil }
    return try JSONDecoder().decode(Config.self, from: Data(contentsOf: paths.configFile))
  }

  public static func save(_ config: Config, _ paths: SupportPaths) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(config).write(to: paths.configFile, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configFile.path)
  }
}

public func findExecutable(_ name: String, path: String?) -> String? {
  let fileManager = FileManager.default
  for directory in (path ?? "").split(separator: ":") where !directory.isEmpty {
    let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
    if fileManager.isExecutableFile(atPath: candidate) { return candidate }
  }
  return nil
}
