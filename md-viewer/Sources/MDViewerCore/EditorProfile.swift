import Foundation

public struct NeovimLaunch: Equatable, Sendable {
  public let socket: String
  public let token: String
  public let controlSocket: String
  public let filesSidecar: String
  public let buffersDirectory: String
  public let plugin: String

  public init(
    socket: String, token: String, controlSocket: String, filesSidecar: String, buffersDirectory: String,
    plugin: String
  ) {
    self.socket = socket
    self.token = token
    self.controlSocket = controlSocket
    self.filesSidecar = filesSidecar
    self.buffersDirectory = buffersDirectory
    self.plugin = plugin
  }
}

extension EditorKind {
  public var displayName: String {
    switch self {
    case .neovim: "Neovim"
    case .vim: "Vim"
    case .helix: "Helix"
    case .emacs: "Emacs"
    case .nano: "nano"
    case .micro: "micro"
    case .kakoune: "Kakoune"
    case .vscode: "VS Code"
    case .cursor: "Cursor"
    case .zed: "Zed"
    case .sublime: "Sublime Text"
    case .terminal: "Editor"
    }
  }
}

public struct EditorProfile: Equatable, Sendable {
  public let kind: EditorKind
  public let runsInTerminal: Bool

  public var syncsLive: Bool { kind == .neovim }

  public var syncDescription: String {
    !runsInTerminal ? "opens outside Rex" : syncsLive ? "live sync" : "refresh on save"
  }

  public init(kind: EditorKind) {
    self.kind = kind
    switch kind {
    case .vscode, .cursor, .zed, .sublime: runsInTerminal = false
    default: runsInTerminal = true
    }
  }

  public static func detectKind(executable: String) -> EditorKind {
    switch basename(executable) {
    case "nvim": .neovim
    case "vim", "vi", "view": .vim
    case "hx", "helix": .helix
    case "emacs", "emacsclient": .emacs
    case "nano": .nano
    case "micro": .micro
    case "kak": .kakoune
    case "code", "code-insiders": .vscode
    case "cursor": .cursor
    case "zed": .zed
    case "subl": .sublime
    default: .terminal
    }
  }

  public static func basename(_ executable: String) -> String {
    executable.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? executable
  }

  public func commandLine(executable: String, words: [String], file: String, line: Int?) -> [String] {
    [executable] + words + emacsFlags(executable: executable, words: words) + lineArguments(file: file, line: line)
  }

  public func lineArguments(file: String, line: Int?) -> [String] {
    guard let line else { return [file] }
    switch kind {
    case .neovim, .vim, .emacs, .nano, .micro, .kakoune: return ["+\(line)", file]
    case .helix, .zed, .sublime: return ["\(file):\(line)"]
    case .vscode, .cursor: return ["-g", "\(file):\(line)"]
    case .terminal: return [file]
    }
  }

  public func neovimCommand(
    executable: String, words: [String], file: String, line: Int?, launch: NeovimLaunch
  ) -> [String]? {
    guard kind == .neovim else { return nil }
    return [
      "/usr/bin/env",
      "MD_VIEWER_SOCKET=\(launch.socket)",
      "MD_VIEWER_TOKEN=\(launch.token)",
      "MD_VIEWER_CONTROL=\(launch.controlSocket)",
      "MD_VIEWER_FILES=\(launch.filesSidecar)",
      "MD_VIEWER_BUFFERS=\(launch.buffersDirectory)",
      "MD_VIEWER_PLUGIN=\(launch.plugin)",
      executable,
    ] + words + [
      "--cmd", "lua dofile(os.getenv('MD_VIEWER_PLUGIN'))",
      "-c", "lua MdViewer.ensure()",
    ] + lineArguments(file: file, line: line)
  }

  private static let terminalFlags: Set<String> = ["-nw", "--no-window-system", "-t", "--tty"]

  private func emacsFlags(executable: String, words: [String]) -> [String] {
    guard kind == .emacs, Set(words).isDisjoint(with: Self.terminalFlags) else { return [] }
    return [Self.basename(executable) == "emacsclient" ? "-t" : "-nw"]
  }
}
