import Foundation

public enum ReportingShell: String, CaseIterable, Sendable {
  case zsh, bash, fish, nushell

  public init?(executable: String) {
    switch (executable as NSString).lastPathComponent {
    case "zsh": self = .zsh
    case "bash": self = .bash
    case "fish": self = .fish
    case "nu": self = .nushell
    default: return nil
    }
  }

  var executableName: String { self == .nushell ? "nu" : rawValue }
}

public enum ShellDirectoryReporting {
  static func beginMarker(_ shell: ReportingShell) -> String {
    "# >>> md-viewer: report the folder to Rex from \(shell.rawValue) (managed by md-viewer setup; edits are replaced) >>>"
  }

  static func endMarker(_ shell: ReportingShell) -> String { "# <<< md-viewer \(shell.rawValue) <<<" }

  public static let fishFileName = "md-viewer-rex-folder.fish"

  public static let zsh = ManagedBlock(
    beginMarker: beginMarker(.zsh), endMarker: endMarker(.zsh),
    body: #"""
      if [[ -o interactive && -n "${REX_BLOCK-}${REX_SESSION-}" ]]; then
        __md_viewer_osc7() {
          emulate -L zsh
          setopt extendedglob
          local LC_ALL=C
          printf '\e]7;file://%s%s\e\\' "$HOST" "${PWD//(#m)[^A-Za-z0-9\/._~-]/%${(l:2::0:)$(( [##16] #MATCH & 255 ))}}"
        }
        __md_viewer_osc7_chpwd() {
          [[ -t 1 ]] && __md_viewer_osc7
          return 0
        }
        autoload -Uz add-zsh-hook
        add-zsh-hook precmd __md_viewer_osc7
        add-zsh-hook chpwd __md_viewer_osc7_chpwd
      fi
      """#)

  public static let bash = ManagedBlock(
    beginMarker: beginMarker(.bash), endMarker: endMarker(.bash),
    body: #"""
      if [ -n "${BASH_VERSION-}" ] && [ -n "${REX_BLOCK-}${REX_SESSION-}" ]; then
        case $- in
        *i*)
          __md_viewer_osc7() {
            local status=$? LC_ALL=C rest="$PWD" url= char hex
            while [ -n "$rest" ]; do
              char=${rest%"${rest#?}"}
              rest=${rest#?}
              case $char in
              [A-Za-z0-9/._~-]) url=$url$char ;;
              *) printf -v hex '%02X' "'$char"; url=$url%${hex#"${hex%??}"} ;;
              esac
            done
            printf '\033]7;file://%s%s\033\\' "$HOSTNAME" "$url"
            return $status
          }
          __md_viewer_osc7_register() {
            case $BASH_VERSION in
            [1-4].* | 5.0.*) ;;
            *)
              case $(declare -p PROMPT_COMMAND 2>/dev/null) in
              "declare -a"*)
                eval 'local entry; for entry in "${PROMPT_COMMAND[@]}"; do [ "$entry" = "__md_viewer_osc7 && :" ] && return; done; PROMPT_COMMAND+=("__md_viewer_osc7 && :")'
                return
                ;;
              esac
              ;;
            esac
            case ${PROMPT_COMMAND-} in
            *__md_viewer_osc7*) ;;
            *) PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND
      }__md_viewer_osc7 && :" ;;
            esac
          }
          __md_viewer_osc7_register
          unset -f __md_viewer_osc7_register
          ;;
        esac
      fi
      """#)

  public static let fish = #"""
    \#(beginMarker(.fish))
    if status is-interactive; and begin; set -q REX_BLOCK; or set -q REX_SESSION; end
        function __md_viewer_osc7 --on-variable PWD --on-event fish_prompt
            status is-command-substitution; and return
            printf '\e]7;file://%s%s\e\\\\' $hostname (string escape --style=url -- $PWD)
        end
    end
    \#(endMarker(.fish))

    """#

  public static func fishEmitsNatively(version output: String) -> Bool {
    guard let range = output.range(of: #"\d+"#, options: .regularExpression), let major = Int(output[range])
    else { return false }
    return major >= 4
  }
}

public struct ShellSetup {
  public struct Change: Equatable, Sendable {
    public let shell: ReportingShell
    public let files: [URL]
  }

  public struct Failure: Equatable, Sendable {
    public let file: URL
    public let reason: String
  }

  public struct Outcome: Equatable, Sendable {
    public var changes: [Change] = []
    public var failures: [Failure] = []
  }

  public var home: URL
  public var environment: [String: String]
  public var loginShell: String?
  public var locate: (String) -> String?
  public var runner: ProcessRunning?
  public var synchronize: (URL) throws -> Void

  public init(
    home: URL, environment: [String: String], loginShell: String?, locate: @escaping (String) -> String?,
    runner: ProcessRunning? = ProcessRunner(timeout: 10),
    synchronize: @escaping (URL) throws -> Void = ManagedFile.fsync
  ) {
    self.home = home
    self.environment = environment
    self.loginShell = loginShell
    self.locate = locate
    self.runner = runner
    self.synchronize = synchronize
  }

  var loginKind: ReportingShell? { loginShell.flatMap(ReportingShell.init(executable:)) }

  func executable(_ shell: ReportingShell) -> String? {
    if loginKind == shell, let loginShell, FileManager.default.isExecutableFile(atPath: loginShell) {
      return loginShell
    }
    return locate(shell.executableName)
  }

  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  public var zshrc: URL {
    zshDirectoryFromZsh().map { URL(fileURLWithPath: $0).appendingPathComponent(".zshrc") } ?? environmentZshrc
  }

  var environmentZshrc: URL {
    let base = environment["ZDOTDIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home
    return base.appendingPathComponent(".zshrc")
  }

  func zshDirectoryFromZsh() -> String? {
    guard let zsh = executable(.zsh), let runner,
      let result = try? runner.run(zsh, ["-c", #"print -r -- "${ZDOTDIR:-$HOME}""#], timeout: 5),
      result.status == 0
    else { return nil }
    let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
    guard let last = lines.last, last.hasPrefix("/") else { return nil }
    return String(last)
  }

  public var bashrc: URL { home.appendingPathComponent(".bashrc") }

  public var bashLoginCandidates: [URL] {
    [".bash_profile", ".bash_login", ".profile"].map { home.appendingPathComponent($0) }
  }

  public var fishFile: URL {
    let base =
      environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent(".config")
    return base.appendingPathComponent("fish/conf.d/\(ShellDirectoryReporting.fishFileName)")
  }

  func fishEmitsNatively() -> Bool {
    guard let fish = executable(.fish), let runner,
      let result = try? runner.run(fish, ["--version"], timeout: 5), result.status == 0
    else { return false }
    return ShellDirectoryReporting.fishEmitsNatively(version: String(decoding: result.stdout, as: UTF8.self))
  }

  func installFiles(_ shell: ReportingShell) -> [URL] {
    guard executable(shell) != nil || loginKind == shell else { return [] }
    let creates = loginKind == shell
    switch shell {
    case .zsh:
      let zshrc = zshrc
      return creates || exists(zshrc) ? [zshrc] : []
    case .bash:
      var files = creates || exists(bashrc) ? [bashrc] : []
      if let login = bashLoginCandidates.first(where: exists) {
        files.append(login)
      } else if creates {
        files.append(bashLoginCandidates[0])
      }
      return files
    case .fish, .nushell:
      return []
    }
  }

  func block(_ shell: ReportingShell) -> ManagedBlock {
    shell == .zsh ? ShellDirectoryReporting.zsh : ShellDirectoryReporting.bash
  }

  static let createdLine =
    "# md-viewer setup created this file; md-viewer uninstall deletes it if nothing else is left."

  func createdBlock(_ shell: ReportingShell) -> ManagedBlock {
    let base = block(shell)
    return ManagedBlock(
      beginMarker: base.beginMarker, endMarker: base.endMarker,
      body: Self.createdLine + "\n"
        + base.text.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n"))
  }

  func wasCreated(_ text: String?) -> Bool {
    text.map { $0.components(separatedBy: "\n").contains(Self.createdLine) } ?? true
  }

  func installing(_ shell: ReportingShell, into existing: String?) throws -> String {
    try (wasCreated(existing) ? createdBlock(shell) : block(shell)).installing(into: existing ?? "")
  }

  func syntaxCheck(_ shell: ReportingShell) -> (URL) throws -> Void {
    { file in
      guard let runner, let path = executable(shell) else { return }
      let arguments = shell == .zsh ? ["-fn", file.path] : ["-n", file.path]
      let result = try runner.run(path, arguments, timeout: 10)
      guard result.status == 0 else {
        let output = String(decoding: result.stderr + result.stdout, as: UTF8.self)
          .split(separator: "\n").joined(separator: "; ")
        throw ManagedFileError.checkFailed(output.isEmpty ? "exit status \(result.status)" : output)
      }
    }
  }

  func edit(_ shell: ReportingShell, _ file: URL, change: (String?) throws -> String?) throws -> Bool {
    let check = syntaxCheck(shell)
    return try ManagedFile.edit(
      file, synchronize: synchronize,
      checksCandidate: { !exists($0) || (try? check($0)) != nil }, check: check, change: change)
  }

  @discardableResult
  public func install() -> Outcome {
    var outcome = Outcome()
    for shell in [ReportingShell.zsh, .bash] {
      var changed: [URL] = []
      for file in installFiles(shell) {
        do {
          if try edit(shell, file, change: { try installing(shell, into: $0) }) { changed.append(file) }
        } catch {
          outcome.failures.append(Failure(file: file, reason: "\(error)"))
        }
      }
      if !changed.isEmpty { outcome.changes.append(Change(shell: shell, files: changed)) }
    }
    if executable(.fish) != nil, !fishEmitsNatively() {
      do {
        if try writeFishFile() { outcome.changes.append(Change(shell: .fish, files: [fishFile])) }
      } catch {
        outcome.failures.append(Failure(file: fishFile, reason: "\(error)"))
      }
    }
    return outcome
  }

  @discardableResult
  public func remove() -> Outcome {
    var outcome = Outcome()
    let zshrcs = [zshrc, environmentZshrc, home.appendingPathComponent(".zshrc")]
    let candidates: [(ReportingShell, [URL])] = [
      (.zsh, zshrcs.enumerated().filter { !zshrcs[..<$0.offset].contains($0.element) }.map(\.element)),
      (.bash, [bashrc] + bashLoginCandidates),
    ]
    for (shell, files) in candidates {
      var changed: [URL] = []
      for file in files where exists(file) {
        do {
          var created = false
          let removed = try edit(shell, file) { existing in
            guard let existing else { return nil }
            created = wasCreated(existing)
            return try block(shell).removing(from: existing)
          }
          if removed {
            changed.append(file)
            if created { try deleteIfEmpty(file) }
          }
        } catch {
          outcome.failures.append(Failure(file: file, reason: "\(error)"))
        }
      }
      if !changed.isEmpty { outcome.changes.append(Change(shell: shell, files: changed)) }
    }
    do {
      if try removeFishFile() { outcome.changes.append(Change(shell: .fish, files: [fishFile])) }
    } catch {
      outcome.failures.append(Failure(file: fishFile, reason: "\(error)"))
    }
    return outcome
  }

  func deleteIfEmpty(_ file: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
      let text = try ManagedFile.read(file), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    try FileManager.default.removeItem(at: file)
  }

  func fishFileIsOurs(_ text: String) -> Bool {
    text.hasPrefix(ShellDirectoryReporting.beginMarker(.fish) + "\n")
  }

  func writeFishFile() throws -> Bool {
    try ManagedFile.edit(fishFile, synchronize: synchronize) { existing in
      if let existing, !fishFileIsOurs(existing) {
        throw ManagedFileError.unreadable("it exists and was not written by md-viewer")
      }
      return ShellDirectoryReporting.fish
    }
  }

  func removeFishFile() throws -> Bool {
    guard let existing = try ManagedFile.read(fishFile), fishFileIsOurs(existing) else { return false }
    try FileManager.default.removeItem(at: fishFile)
    return true
  }

  public func isReporting(_ shell: ReportingShell) -> Bool {
    switch shell {
    case .zsh:
      return ((try? ManagedFile.read(zshrc)) ?? nil).map(ShellDirectoryReporting.zsh.isPresent(in:)) ?? false
    case .bash:
      guard let login = bashLoginCandidates.first(where: exists) else { return false }
      return ((try? ManagedFile.read(login)) ?? nil).map(ShellDirectoryReporting.bash.isPresent(in:)) ?? false
    case .fish:
      return fishEmitsNatively() || (((try? ManagedFile.read(fishFile)) ?? nil).map(fishFileIsOurs) ?? false)
    case .nushell:
      return true
    }
  }

  public func doctorLines(rexPath: String?) -> [DiagnosticLine] {
    guard let loginShell else { return [] }
    var lines: [DiagnosticLine] = []
    let name = (loginShell as NSString).lastPathComponent
    if let shell = loginKind {
      lines.append(
        isReporting(shell)
          ? DiagnosticLine(
            level: .ok, text: "\(name) reports its folder to Rex, so relative Markdown paths are clickable")
          : DiagnosticLine(
            level: .fail,
            text: "\(name) does not report its folder to Rex, so only absolute Markdown paths are clickable;"
              + " run md-viewer setup"))
    } else {
      lines.append(
        DiagnosticLine(
          level: .info,
          text: "\(name) is not set up to report its folder to Rex; only absolute Markdown paths are clickable"))
    }
    if let live = liveReport(rexPath: rexPath) { lines.append(live) }
    return lines
  }

  func liveReport(rexPath: String?) -> DiagnosticLine? {
    guard let rexPath, let runner, let block = environment["REX_BLOCK"], !block.isEmpty,
      let result = try? runner.run(
        rexPath, ["block", "call", "-b", block, "pwd", "{}", "--autostart=false"], timeout: 5),
      result.status == 0
    else { return nil }
    let reported = String(decoding: result.stdout, as: UTF8.self).contains("file://")
    return DiagnosticLine(
      level: .info,
      text: reported
        ? "this Rex pane reports its folder"
        : "this Rex pane has not reported its folder; new panes pick up md-viewer setup's changes")
  }
}

public func loginShellPath(environment: [String: String]) -> String? {
  if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
    let path = String(cString: shell)
    if !path.isEmpty { return path }
  }
  return environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 }
}

public func shellSetupLines(_ outcome: ShellSetup.Outcome, installing: Bool) -> [String] {
  outcome.changes.map { change in
    let files = change.files.map(\.path).joined(separator: ", ")
    return installing
      ? "\(change.shell.rawValue) now reports its folder to Rex, so relative Markdown paths are clickable in new panes (\(files))."
      : "Removed md-viewer's folder reporting for \(change.shell.rawValue) from \(files)."
  }
}

public func shellFailureLines(_ outcome: ShellSetup.Outcome, installing: Bool) -> [String] {
  outcome.failures.map {
    "Left \($0.file.path) unchanged because \($0.reason). Folder reporting was not \(installing ? "set up" : "removed")."
  }
}
