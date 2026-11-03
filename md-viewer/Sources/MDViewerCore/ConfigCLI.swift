import Foundation

public let configUsage = "usage: md-viewer config [get <name> | set <name> <value> | unset <name>]"

public enum ConfigAction: Equatable, Sendable {
  case show
  case get(SettingKey)
  case set(SettingKey, String)
  case unset(SettingKey)
}

public struct ConfigOutput: Equatable, Sendable {
  public var status: Int32
  public var stdout: String
  public var stderr: String

  static func ok(_ stdout: String) -> ConfigOutput { ConfigOutput(status: 0, stdout: stdout, stderr: "") }

  static func failure(_ stderr: String, status: Int32) -> ConfigOutput {
    ConfigOutput(status: status, stdout: "", stderr: stderr)
  }
}

extension SettingKey {
  public var cliName: String {
    switch self {
    case .previews: "previews"
    case .editMode: "edit-mode"
    case .editor: "editor"
    case .editorKind: "editor-kind"
    }
  }

  public init?(cliName: String) {
    guard let key = Self.allCases.first(where: { $0.cliName == cliName }) else { return nil }
    self = key
  }

  var allowedValues: [String]? {
    switch self {
    case .previews: ["perFile", "single"]
    case .editMode: EditMode.allCases.map(\.rawValue)
    case .editorKind: EditorKind.allCases.map(\.rawValue)
    case .editor: nil
    }
  }
}

public enum ConfigCommandLine {
  public static func parse(_ arguments: [String]) -> Result<ConfigAction, OpenArgumentsError> {
    func usage(_ message: String = configUsage) -> Result<ConfigAction, OpenArgumentsError> {
      .failure(OpenArgumentsError(description: message))
    }
    guard let verb = arguments.first else { return .success(.show) }
    let rest = Array(arguments.dropFirst())
    let expected = verb == "set" ? 2 : 1
    guard ["get", "set", "unset"].contains(verb), rest.count == expected else { return usage() }
    guard let key = SettingKey(cliName: rest[0]) else {
      let names = SettingKey.allCases.map(\.cliName).joined(separator: ", ")
      return usage("unknown setting: \(rest[0]) (settings: \(names))")
    }
    switch verb {
    case "get": return .success(.get(key))
    case "unset": return .success(.unset(key))
    default: return .success(.set(key, rest[1]))
    }
  }
}

public struct ConfigRunner {
  public let paths: SupportPaths
  public let makeResolver: (Settings) -> EditorResolver

  public init(paths: SupportPaths, makeResolver: @escaping (Settings) -> EditorResolver) {
    self.paths = paths
    self.makeResolver = makeResolver
  }

  public func run(_ action: ConfigAction) -> ConfigOutput {
    switch action {
    case .show: show()
    case .get(let key): get(key)
    case .set(let key, let value): set(key, value)
    case .unset(let key): unset(key)
    }
  }

  private struct Effective {
    var value: String?
    var source: String
  }

  private func isSet(_ key: SettingKey) -> Bool {
    guard let value = ConfigStore.readObject(paths)[key.rawValue] as? String else { return false }
    return key.isValid(value)
  }

  private func effective(_ key: SettingKey, settings: Settings, resolution: EditorResolution) -> Effective {
    let explicit = isSet(key)
    switch key {
    case .previews: return Effective(value: settings.previews.rawValue, source: explicit ? "setting" : "default")
    case .editMode: return Effective(value: settings.editMode.rawValue, source: explicit ? "setting" : "default")
    case .editor:
      if let editor = settings.editor { return Effective(value: editor, source: "setting") }
      guard case .resolved(let resolved) = resolution.outcome else { return Effective(value: nil, source: "unset") }
      return Effective(
        value: ([resolved.executable] + resolved.words).joined(separator: " "), source: describe(resolved.source))
    case .editorKind:
      if let kind = settings.editorKind { return Effective(value: kind.rawValue, source: "setting") }
      guard case .resolved(let resolved) = resolution.outcome else { return Effective(value: nil, source: "unset") }
      return Effective(value: resolved.kind.rawValue, source: "detected")
    }
  }

  private func describe(_ source: EditorSource) -> String {
    switch source {
    case .setting: "setting"
    case .ownEnvironment(let name): "$\(name)"
    case .loginEnvironment(let name): "$\(name) from your login shell"
    }
  }

  private func get(_ key: SettingKey) -> ConfigOutput {
    let settings = SettingsStore.load(paths)
    let resolution = makeResolver(settings).resolve()
    guard let value = effective(key, settings: settings, resolution: resolution).value else {
      return ConfigOutput(status: 1, stdout: "", stderr: "")
    }
    return .ok(value + "\n")
  }

  private func show() -> ConfigOutput {
    let settings = SettingsStore.load(paths)
    let resolver = makeResolver(settings)
    let resolution = resolver.resolve()
    var lines = SettingKey.allCases.map { key -> String in
      let entry = effective(key, settings: settings, resolution: resolution)
      return "\(key.cliName.padding(toLength: 12, withPad: " ", startingAt: 0))\(entry.value ?? "-")  (\(entry.source))"
    }
    lines.append("")
    lines.append("Editor resolution: \(resolutionLine(settings, resolution))")
    lines += resolution.notices.map { "note: \($0)" }
    let detected = resolver.candidates()
    lines.append(
      detected.isEmpty
        ? "Detected editors: none"
        : "Detected editors: " + detected.map { "\($0.name) (\($0.executable))" }.joined(separator: ", "))
    return .ok(lines.joined(separator: "\n") + "\n")
  }

  private func resolutionLine(_ settings: Settings, _ resolution: EditorResolution) -> String {
    switch resolution.outcome {
    case .resolved(let editor):
      let behavior =
        !editor.profile.runsInTerminal
        ? "opens outside Rex" : editor.profile.syncsLive ? "live sync" : "refresh on save"
      return "\(editor.executable) (\(describe(editor.source))), \(editor.kind.rawValue), \(behavior)"
    case .stopped:
      let value = settings.editor ?? ""
      return "editor setting: \((ShellWords.split(value)?.first ?? value)) not found"
    case .needsPicker:
      return "no editor set; previews will ask on first e"
    }
  }

  private func set(_ key: SettingKey, _ value: String) -> ConfigOutput {
    guard key.isValid(value) else {
      let expected = key.allowedValues.map { " (expected \($0.joined(separator: ", ")))" } ?? ""
      return .failure("invalid value for \(key.cliName): \(value)\(expected)", status: 64)
    }
    if key == .editor {
      guard let first = ShellWords.split(value)?.first else {
        return .failure("invalid editor command: \(value)", status: 64)
      }
      var candidate = Settings()
      candidate.editor = value
      guard case .resolved = makeResolver(candidate).resolve().outcome else {
        return .failure("not found: \(first)", status: 1)
      }
    }
    do {
      try SettingsStore.update(paths, set: [key: value])
    } catch {
      return .failure("config set failed: \(error)", status: 1)
    }
    return .ok("\(key.cliName) = \(value)\n")
  }

  private func unset(_ key: SettingKey) -> ConfigOutput {
    do {
      try SettingsStore.update(paths, unset: [key])
    } catch {
      return .failure("config unset failed: \(error)", status: 1)
    }
    return .ok("\(key.cliName) unset\n")
  }
}
