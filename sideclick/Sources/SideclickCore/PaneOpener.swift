import Foundation

public struct OpenError: Error, Equatable, CustomStringConvertible {
  public let description: String

  public init(_ description: String) {
    self.description = description
  }
}

public enum OpenOutcome: Equatable, Sendable {
  case newTab(browser: String)
  case split(PaneTarget)
}

public enum PaneCommand: Equatable, Sendable {
  case terminalBrowser(path: String)
  case direct(name: String, path: String)
  case custom(command: String)

  public static func resolve(browser: BrowserChoice, browserPath: String?) throws -> PaneCommand {
    switch browser {
    case .custom(let command):
      return .custom(command: command)
    case .builtIn(let builtIn):
      guard let browserPath, !browserPath.isEmpty else {
        throw OpenError("no path recorded for \(builtIn.name); run sideclick setup")
      }
      return builtIn == .terminalBrowser
        ? .terminalBrowser(path: browserPath) : .direct(name: builtIn.name, path: browserPath)
    }
  }

  var label: String {
    switch self {
    case .terminalBrowser: "terminal-browser"
    case .direct(let name, _): name
    case .custom: "sideclick"
    }
  }

  func arguments(url: URL) -> [String] {
    switch self {
    case .terminalBrowser(let path): ["--shell=none", "--", path, "open", url.absoluteString]
    case .direct(_, let path): ["--shell=none", "--", path, url.absoluteString]
    case .custom(let command): ["--", "/bin/sh", "-c", customShellScript(command), "sideclick", url.absoluteString]
    }
  }
}

let psPath = "/bin/ps"

public func newTabArguments(browser: String, url: URL) -> [String] {
  ["new-tab", "--browser", browser, url.absoluteString]
}

public func splitArguments(target: PaneTarget, url: URL, command: PaneCommand) -> [String] {
  rexGlobalArguments + [
    "run", "--session", target.session, "--block", target.block,
    "--split", "right", "--ratio", "50",
    "--label", command.label,
  ] + command.arguments(url: url)
}

public func focusArguments(session: String, block: String) -> [String] {
  rexGlobalArguments + ["focus", "--session", session, block]
}

let rexGlobalArguments = ["--autostart=false"]
let browserProbeInterval: TimeInterval = 0.1

public struct PaneOpener: Sendable {
  public var runner: CommandRunning
  public var rexPath: String
  public var command: PaneCommand
  public var startupWindow: TimeInterval
  public var now: @Sendable () -> Date
  public var sleep: @Sendable (TimeInterval) -> Void

  public init(
    runner: CommandRunning, rexPath: String, command: PaneCommand, startupWindow: TimeInterval = 5,
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) {
    self.runner = runner
    self.rexPath = rexPath
    self.command = command
    self.startupWindow = startupWindow
    self.now = now
    self.sleep = sleep
  }

  public func open(_ url: URL, lastFocusedSession: String?) throws -> OpenOutcome {
    let clients = try rex(["client", "ls", "--json"])
    guard let session = selectSession(lastFocused: lastFocusedSession, clientListJSON: clients) else {
      throw OpenError("no Rex app is attached to a session")
    }
    let inspect = try rex(["session", "inspect", session, "--json"])
    guard let target = focusedPane(sessionInspectJSON: inspect, session: session) else {
      throw OpenError("session \(session) has no focused pane")
    }

    guard case .terminalBrowser(let terminalBrowserPath) = command else {
      try require(runner.run(rexPath, splitArguments(target: target, url: url, command: command)), "rex run")
      return .split(target)
    }

    let running = try runningBrowsers(terminalBrowserPath)
    if let browser = try existingBrowser(beside: target, running: running) {
      try require(
        runner.run(terminalBrowserPath, newTabArguments(browser: browser.key, url: url)), "terminal-browser new-tab")
      _ = try? runner.run(rexPath, focusArguments(session: target.session, block: browser.block))
      return .newTab(browser: browser.key)
    }
    try require(runner.run(rexPath, splitArguments(target: target, url: url, command: command)), "rex run")
    waitForNewBrowser(terminalBrowserPath, besides: Set(running.map(\.key)))
    return .split(target)
  }

  private func runningBrowsers(_ terminalBrowserPath: String) throws -> [BrowserInstance] {
    let listed = try runner.run(terminalBrowserPath, ["ls", "--all", "--json"])
    guard listed.status == 0 else { return [] }
    return browsers(listJSON: listed.stdout)
  }

  private func waitForNewBrowser(_ terminalBrowserPath: String, besides known: Set<String>) {
    let deadline = now().addingTimeInterval(startupWindow)
    while now() < deadline {
      let running = (try? runningBrowsers(terminalBrowserPath)) ?? []
      if running.contains(where: { !known.contains($0.key) }) { return }
      sleep(browserProbeInterval)
    }
  }

  private func existingBrowser(beside target: PaneTarget, running: [BrowserInstance]) throws -> BrowserPane? {
    guard !running.isEmpty else { return nil }

    let listed = try runner.run(rexPath, rexGlobalArguments + ["block", "ls", "--session", target.session, "--json"])
    guard listed.status == 0 else { return nil }
    let blocks = windowBlocks(blockListJSON: listed.stdout, target: target)
    var pids: [String: Int32] = [:]
    for block in blocks {
      let process = try runner.run(
        rexPath, rexGlobalArguments + ["block", "call", "--session", target.session, "--block", block, "process"])
      if process.status == 0, let pid = childPID(processJSON: process.stdout) { pids[block] = pid }
    }
    guard !pids.isEmpty else { return nil }

    let pidList = Set(pids.values).sorted().map(String.init).joined(separator: ",")
    let ttys = processTTYs(psOutput: try runner.run(psPath, ["-o", "pid=,tty=", "-p", pidList]).stdout)
    let blockTTYs = pids.compactMapValues { ttys[$0] }
    return matchingBrowser(blocks: blocks, blockTTYs: blockTTYs, browsers: running)
  }

  private func rex(_ arguments: [String]) throws -> Data {
    try require(
      runner.run(rexPath, rexGlobalArguments + arguments), "rex \(arguments.prefix(2).joined(separator: " "))"
    )
    .stdout
  }

  @discardableResult
  private func require(_ result: CommandResult, _ what: String) throws -> CommandResult {
    guard result.status == 0 else {
      throw OpenError("\(what) exited with \(result.status): \(result.stderrText)")
    }
    return result
  }
}
