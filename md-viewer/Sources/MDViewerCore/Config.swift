import Foundation

public enum PreviewMode: String, Sendable {
  case perFile
  case single
}

public struct Config: Codable, Equatable, Sendable {
  public var rexPath: String
  public var mdViewerPath: String
  public var previousHandlers: [String: String]
  public var previews: String?

  public init(
    rexPath: String, mdViewerPath: String, previousHandlers: [String: String], previews: String? = nil
  ) {
    self.rexPath = rexPath
    self.mdViewerPath = mdViewerPath
    self.previousHandlers = previousHandlers
    self.previews = previews
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rexPath = try container.decode(String.self, forKey: .rexPath)
    mdViewerPath = try container.decode(String.self, forKey: .mdViewerPath)
    previousHandlers = try container.decode([String: String].self, forKey: .previousHandlers)
    previews = try? container.decodeIfPresent(String.self, forKey: .previews)
  }

  public var previewMode: PreviewMode {
    previews.flatMap(PreviewMode.init(rawValue:)) ?? .perFile
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
    let existing =
      (try? Data(contentsOf: paths.configFile))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any] ?? [:]
    let merged = existing.merging(encoded) { _, new in new }
    try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      .write(to: paths.configFile, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configFile.path)
  }
}
