import Foundation

public struct Config: Codable, Equatable, Sendable {
  public var rexPath: String
  public var mdViewerPath: String
  public var previousHandlers: [String: String]

  public init(rexPath: String, mdViewerPath: String, previousHandlers: [String: String]) {
    self.rexPath = rexPath
    self.mdViewerPath = mdViewerPath
    self.previousHandlers = previousHandlers
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
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.root.path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(config).write(to: paths.configFile, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configFile.path)
  }
}
