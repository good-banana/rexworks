import Foundation
import MDViewerCore
import MDViewerInteraction
import XCTest

@testable import MDViewerHost

func rexFixture(_ name: String) throws -> Data {
  let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  return try Data(contentsOf: directory.appendingPathComponent("MDViewerCoreTests/Fixtures/\(name)"))
}

func runJSON(block: String) -> Data {
  Data(#"{"block_ids":["\#(block)"]}"#.utf8)
}

final class ShortHome {
  let url: URL

  init() throws {
    url = URL(fileURLWithPath: "/tmp/mdv-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }
}

final class FakeRexRunner: ProcessRunning, @unchecked Sendable {
  struct Call: Equatable {
    var executable: String
    var arguments: [String]
    var onMainThread: Bool
  }

  typealias Result = (status: Int32, stdout: Data, stderr: Data)

  private let lock = NSLock()
  private var recorded: [Call] = []
  private var replies: [String: Result] = [:]
  private var queuedRuns: [Result] = []
  var runGate: DispatchSemaphore?
  var onRun: (@Sendable ([String]) -> Void)?
  var loginEnvironment = "PATH=/fake/bin\u{0}LANG=en_US.UTF-8\u{0}"

  var calls: [Call] { lock.withLock { recorded } }
  var rexCalls: [[String]] { calls.filter { $0.executable == "/fake/rex" }.map(\.arguments) }

  func reply(to command: String, _ result: Result) {
    lock.withLock { replies[command] = result }
  }

  func queueRun(_ result: Result) {
    lock.withLock { queuedRuns.append(result) }
  }

  func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> Result {
    lock.withLock {
      recorded.append(Call(executable: executable, arguments: arguments, onMainThread: Thread.isMainThread))
    }
    if executable != "/fake/rex" { return (0, Data(loginEnvironment.utf8), Data()) }
    let command = arguments.prefix(2).joined(separator: " ")
    if arguments.first == "run" {
      onRun?(arguments)
      runGate?.wait()
      if let queued = lock.withLock({ queuedRuns.isEmpty ? nil : queuedRuns.removeFirst() }) { return queued }
    }
    if let reply = lock.withLock({ replies[command] ?? replies[arguments.first ?? ""] }) { return reply }
    switch arguments.first {
    case "run": return (0, try rexFixture("rex-run.json"), Data())
    case "block" where arguments.dropFirst().first == "ls": return (0, try rexFixture("rex-block-ls.json"), Data())
    default: return (0, Data(), Data())
    }
  }
}

final class FakeControl: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [(EditorControlCommand, URL)] = []
  var succeeds = true
  var onSend: (@Sendable (EditorControlCommand) -> Void)?

  var commands: [EditorControlCommand] { lock.withLock { recorded.map(\.0) } }
  var sockets: [URL] { lock.withLock { recorded.map(\.1) } }

  func send(_ command: EditorControlCommand, _ socket: URL) -> Bool {
    onSend?(command)
    lock.withLock { recorded.append((command, socket)) }
    return succeeds
  }
}

final class FakeWaitProcess: PaneWaitProcess, @unchecked Sendable {
  let arguments: [String]
  let finished: @Sendable (Data) -> Void
  private let lock = NSLock()
  private var wasStopped = false

  init(arguments: [String], finished: @escaping @Sendable (Data) -> Void) {
    self.arguments = arguments
    self.finished = finished
  }

  var block: String { arguments[1] }
  var stopped: Bool { lock.withLock { wasStopped } }

  func stop() { lock.withLock { wasStopped = true } }
}

final class FakeWaits: @unchecked Sendable {
  private let lock = NSLock()
  private var started: [FakeWaitProcess] = []

  var processes: [FakeWaitProcess] { lock.withLock { started } }

  var launcher: PaneWaitLauncher {
    { [self] arguments, finished in
      let process = FakeWaitProcess(arguments: arguments, finished: finished)
      lock.withLock { started.append(process) }
      return process
    }
  }

  func running(_ block: String) -> FakeWaitProcess? {
    processes.last { $0.block == block && !$0.stopped }
  }
}

final class FakeGUILauncher: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [EditorLaunch] = []

  var launches: [EditorLaunch] { lock.withLock { recorded } }

  func launch(_ launch: EditorLaunch) throws {
    lock.withLock { recorded.append(launch) }
  }
}

final class TokenSource: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func next() -> String {
    lock.withLock {
      count += 1
      return "token-\(count)"
    }
  }
}

@MainActor
final class EditorFixture {
  static let session = "session:1"
  static let previewBlock = "block:preview"
  static let launchedBlock = "block:01a1a2b7-d61a-74b3-9771-06d6aa61e8f6"

  let host: ViewerHost
  let hostFixture: HostFixture
  let home: ShortHome
  let paths: SupportPaths
  let runner = FakeRexRunner()
  let control = FakeControl()
  let waits = FakeWaits()
  let gui = FakeGUILauncher()
  let tokens = TokenSource()
  let coordinator: EditorCoordinator
  var handoffs: [EditorLaunch] = []

  init(
    _ markdown: String = "# Title\n\nBody text.\n", files: [String: String] = [:], editor: String? = "nvim",
    inRex: Bool = true
  ) throws {
    hostFixture = try HostFixture(markdown, files: files)
    host = hostFixture.host
    home = try ShortHome()
    paths = SupportPaths(home: home.url)
    if let editor { try SettingsStore.update(paths, set: [.editor: editor]) }
    let control = control
    let gui = gui
    let tokens = tokens
    let system = EditorSystem(
      runner: runner, isExecutable: { $0.hasPrefix("/fake/bin/") || $0 == "/bin/zsh" },
      sendControl: { control.send($0, $1) }, launchGUI: { try gui.launch($0) }, paneWait: waits.launcher,
      makeToken: { tokens.next() })
    let context = EditorContext(
      paths: paths, rexPath: "/fake/rex", session: inRex ? Self.session : nil, block: Self.previewBlock,
      previewSocket: home.url.appendingPathComponent("preview.sock"),
      ownEnvironment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin"])
    coordinator = EditorCoordinator(context: context, system: system)
    coordinator.onHandoff = { [unowned self] in handoffs.append($0) }
    host.attachEditor(coordinator)
  }

  var file: URL { hostFixture.file }
  var registry: EditorRegistry { EditorRegistry(paths: paths) }
  var status: String? { host.interaction.status.message?.text }

  func press(_ mode: EditRequestMode = .configured, line: Int = 1) {
    host.perform(.edit(EditRequest(mode: mode, line: line)))
  }

  func waitIdle() {
    spin(until: { !self.coordinator.isBusy })
    spin(0.05)
  }

  @discardableResult
  func launchNeovim(block: String = EditorFixture.launchedBlock) -> String {
    runner.queueRun((0, runJSON(block: block), Data()))
    press()
    spin(until: { self.coordinator.link.block == block && !self.coordinator.isBusy })
    return coordinator.link.token ?? ""
  }

  func envelope(_ token: String, _ seq: Int, file: URL? = nil) -> PluginEnvelope {
    PluginEnvelope(token: token, seq: seq, file: (file ?? self.file).path)
  }

  func writeBuffer(_ text: String, name: String = "1-1.md") throws -> URL {
    let directory = paths.buffersDirectory
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  func neovimEntry(block: String, files: [URL], mode: EditMode = .split) -> EditorEntry {
    EditorEntry(
      block: block, mode: mode, session: Self.session, files: files.map(\.path), kind: .neovim,
      controlSocket: paths.neovimControlSocket(id: block.replacingOccurrences(of: ":", with: "")).path)
  }

  func write(_ entry: EditorEntry) throws {
    try registry.withLock { try registry.write(entry, under: $0) }
  }
}
