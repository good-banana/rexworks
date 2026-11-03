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

public enum EditMode: String, Codable, Sendable, CaseIterable {
  case split
  case here
}

public enum EditorKind: String, Codable, Sendable, CaseIterable {
  case neovim
  case vim
  case helix
  case emacs
  case nano
  case micro
  case kakoune
  case vscode
  case cursor
  case zed
  case sublime
  case terminal
}

public enum SettingKey: String, Sendable, CaseIterable {
  case previews
  case editMode
  case editor
  case editorKind

  public func isValid(_ value: String) -> Bool {
    switch self {
    case .previews: PreviewMode(rawValue: value) != nil
    case .editMode: EditMode(rawValue: value) != nil
    case .editorKind: EditorKind(rawValue: value) != nil
    case .editor: !value.trimmingCharacters(in: .whitespaces).isEmpty
    }
  }
}

public struct Settings: Equatable, Sendable {
  public var previews: PreviewMode = .perFile
  public var editMode: EditMode = .split
  public var editor: String?
  public var editorKind: EditorKind?

  public init() {}

  public init(data: Data?) {
    let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    self.init(object: object)
  }

  init(object: [String: Any]) {
    previews = (object[SettingKey.previews.rawValue] as? String).flatMap(PreviewMode.init(rawValue:)) ?? .perFile
    editMode = (object[SettingKey.editMode.rawValue] as? String).flatMap(EditMode.init(rawValue:)) ?? .split
    editor = (object[SettingKey.editor.rawValue] as? String).flatMap { $0.isEmpty ? nil : $0 }
    editorKind = (object[SettingKey.editorKind.rawValue] as? String).flatMap(EditorKind.init(rawValue:))
  }
}

public struct SettingsError: Error, Equatable, CustomStringConvertible {
  public let message: String
  public var description: String { message }
}

public enum SettingsStore {
  public static func load(_ paths: SupportPaths) -> Settings {
    Settings(data: try? Data(contentsOf: paths.configFile))
  }

  public static func update(
    _ paths: SupportPaths, set: [SettingKey: String] = [:], unset: [SettingKey] = []
  ) throws {
    for (key, value) in set where !key.isValid(value) {
      throw SettingsError(message: "invalid value for \(key.rawValue): \(value)")
    }
    try ConfigStore.withLock(paths) {
      var object = try ConfigStore.readObjectForUpdate(paths)
      for key in unset { object.removeValue(forKey: key.rawValue) }
      for (key, value) in set { object[key.rawValue] = value }
      try ConfigStore.write(object, paths)
    }
  }
}

public enum ConfigStore {
  public static func load(_ paths: SupportPaths) throws -> Config? {
    guard FileManager.default.fileExists(atPath: paths.configFile.path) else { return nil }
    let data = try Data(contentsOf: paths.configFile)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SettingsError(message: "\(paths.configFile.path) is not a JSON object")
    }
    guard object["rexPath"] != nil else { return nil }
    return try JSONDecoder().decode(Config.self, from: data)
  }

  public static func save(_ config: Config, _ paths: SupportPaths) throws {
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any] ?? [:]
    try withLock(paths) {
      try write(readObjectForUpdate(paths).merging(encoded) { _, new in new }, paths)
    }
  }

  static func withLock<T>(_ paths: SupportPaths, _ body: () throws -> T) throws -> T {
    try prepareRoot(paths)
    guard let lock = OpenLock.acquire(paths.configLock) else {
      throw SettingsError(message: "cannot lock \(paths.configLock.path)")
    }
    defer { lock.release() }
    return try body()
  }

  static func readObject(_ paths: SupportPaths) -> [String: Any] {
    (try? Data(contentsOf: paths.configFile))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
  }

  static func readObjectForUpdate(_ paths: SupportPaths) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: paths.configFile.path) else { return [:] }
    guard
      let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: paths.configFile)) as? [String: Any]
    else {
      throw SettingsError(message: "\(paths.configFile.path) is not a valid JSON object; fix or remove it")
    }
    return object
  }

  static func write(_ object: [String: Any], _ paths: SupportPaths) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      .write(to: paths.configFile, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configFile.path)
  }

  private static func prepareRoot(_ paths: SupportPaths) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.root.path)
  }
}
