import Foundation

public enum EditorSetup {
  public static func apply(
    paths: SupportPaths, ownEnvironment: [String: String], isExecutable: @escaping (String) -> Bool
  ) -> String {
    let settings = SettingsStore.load(paths)
    if let editor = settings.editor {
      return "Editor for previews: \(editor) (change it with md-viewer config set editor <command>)"
    }
    let resolver = EditorResolver(
      settings: settings, ownEnvironment: ownEnvironment,
      loginEnvironment: { LoginEnvironment(variables: ownEnvironment) }, isExecutable: isExecutable)
    guard case .resolved(let editor) = resolver.resolve().outcome,
      case .ownEnvironment(let name) = editor.source, let value = ownEnvironment[name]
    else {
      return "No editor set; previews will ask on first e, or run md-viewer config set editor <command>"
    }
    do {
      try SettingsStore.update(paths, set: [.editor: value])
    } catch {
      return "Could not save \(value) from $\(name) as the editor for previews: \(error)"
    }
    return
      "Saved \(value) from $\(name) as the editor for previews; change it with md-viewer config set editor <command>"
  }
}

public struct NeovimVersion: Equatable, Sendable {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public static let timeout: TimeInterval = 3

  public var text: String { "\(major).\(minor).\(patch)" }
  public var supportsLiveSync: Bool { major > 0 || minor >= 9 }

  public static func parse(_ output: String) -> NeovimVersion? {
    guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("NVIM v") }) else { return nil }
    let numbers = line.dropFirst("NVIM v".count).split(whereSeparator: { !$0.isNumber && $0 != "." }).first ?? ""
    let parts = numbers.split(separator: ".").compactMap { Int($0) }
    guard parts.count >= 2 else { return nil }
    return NeovimVersion(major: parts[0], minor: parts[1], patch: parts.count > 2 ? parts[2] : 0)
  }

  public static func probe(executable: String, runner: ProcessRunning) -> NeovimVersion? {
    guard let result = try? runner.run(executable, ["--version"], timeout: timeout), result.status == 0
    else { return nil }
    return parse(String(decoding: result.stdout, as: UTF8.self))
  }
}

public struct DiagnosticLine: Equatable, Sendable {
  public enum Level: Equatable, Sendable {
    case ok, fail, info
  }

  public let level: Level
  public let text: String
}

public enum EditorDoctor {
  public static func lines(
    settings: Settings, resolution: EditorResolution, neovimVersion: (String) -> NeovimVersion?
  ) -> [DiagnosticLine] {
    var lines: [DiagnosticLine] = []
    switch resolution.outcome {
    case .resolved(let editor):
      let value = ([EditorProfile.basename(editor.executable)] + editor.words).joined(separator: " ")
      lines.append(
        DiagnosticLine(
          level: .ok,
          text:
            "editor \(value) at \(editor.executable) (\(editor.source.label)), \(editor.kind.displayName), \(editor.profile.syncDescription)"
        ))
      if editor.kind == .neovim { lines.append(neovimLine(neovimVersion(editor.executable))) }
    case .stopped:
      let setting = settings.editor ?? ""
      let name = ShellWords.split(setting)?.first ?? setting
      lines.append(
        DiagnosticLine(
          level: .fail, text: "editor setting: \(name) not found (md-viewer config set editor <command>)"))
    case .needsPicker:
      lines.append(
        DiagnosticLine(level: .info, text: "editor not set; previews will ask on first e"))
    }
    lines += resolution.notices.map { DiagnosticLine(level: .info, text: $0) }
    lines.append(DiagnosticLine(level: .info, text: "edit-mode \(settings.editMode.rawValue)"))
    return lines
  }

  private static func neovimLine(_ version: NeovimVersion?) -> DiagnosticLine {
    guard let version else {
      return DiagnosticLine(level: .fail, text: "Neovim version could not be read (live sync needs 0.9 or later)")
    }
    return DiagnosticLine(
      level: version.supportsLiveSync ? .ok : .fail,
      text: "Neovim \(version.text) supports live sync (0.9 or later)")
  }
}
