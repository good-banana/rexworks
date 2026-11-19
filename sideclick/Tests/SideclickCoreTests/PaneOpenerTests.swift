import Foundation
import SideclickCore
import Testing

struct PaneOpenerTests {
  let rex = "/opt/rex"
  let terminalBrowser = "/opt/terminal-browser"
  let link = URL(string: "https://example.com/a path?q=\"x\"#frag")!

  func responder(
    browsersJSON: Data, tty: String, overrides: [String: CommandResult] = [:]
  ) throws -> @Sendable (String, [String]) -> CommandResult {
    let clients = try fixture("client-ls")
    let inspect = try fixture("session-inspect")
    let blocks = try fixture("block-ls")
    let process = try fixture("block-process")
    let rex = rex
    let terminalBrowser = terminalBrowser
    return { executable, arguments in
      let command = arguments.filter { $0 != "--autostart=false" }.prefix(2).joined(separator: " ")
      if let override = overrides[command] { return override }
      switch (executable, command) {
      case (rex, "client ls"): return ok(clients)
      case (rex, "session inspect"): return ok(inspect)
      case (rex, "block ls"): return ok(blocks)
      case (rex, "block call"): return ok(process)
      case (rex, "run --session"): return ok("{}")
      case (rex, "focus --session"): return ok("")
      case ("/bin/ps", _): return ok("53648 \(tty)\n")
      case (terminalBrowser, "ls --all"): return ok(browsersJSON)
      case (terminalBrowser, "new-tab --browser"): return ok("opened tab")
      default: return CommandResult(status: 99, stderr: Data("unexpected \(executable) \(arguments)".utf8))
      }
    }
  }

  func opener(_ runner: FakeRunner) -> PaneOpener {
    let clock = FakeClock()
    return PaneOpener(
      runner: runner, rexPath: rex, command: .terminalBrowser(path: terminalBrowser), startupWindow: 0.3,
      now: clock.now,
      sleep: clock.advance)
  }

  func splitCall(_ runner: FakeRunner) -> FakeRunner.Call? {
    runner.calls.first { $0.executable == rex && $0.arguments.contains("run") }
  }

  @Test func waitsForTheNewBrowserSoAQuickSecondClickOpensATab() throws {
    let empty = Data(#"{"browsers":[]}"#.utf8)
    let started = Data(#"{"browsers":[{"key":"new-1","tty":"/dev/ttys009"}]}"#.utf8)
    let split = LockedFlag()
    let base = try responder(browsersJSON: empty, tty: "ttys009")
    let runner = FakeRunner { executable, arguments in
      if arguments.contains("run") { split.set() }
      if executable == "/opt/terminal-browser", arguments.first == "ls" { return ok(split.isSet ? started : empty) }
      return base(executable, arguments)
    }
    let opener = opener(runner)

    #expect(
      try opener.open(link, lastFocusedSession: "session:focused")
        == .split(
          PaneTarget(session: "session:focused", window: "window:active", block: "block:shell")))
    #expect(runner.calls.last?.arguments.first == "ls")
    #expect(try opener.open(link, lastFocusedSession: "session:focused") == .newTab(browser: "new-1"))
    #expect(runner.calls.filter { $0.arguments.contains("run") }.count == 1)
  }

  @Test func stopsWaitingForTheNewBrowserAfterTheStartupWindow() throws {
    let runner = FakeRunner(try responder(browsersJSON: Data(#"{"browsers":[]}"#.utf8), tty: "ttys009"))
    _ = try opener(runner).open(link, lastFocusedSession: "session:focused")
    let probesAfterSplit = runner.calls.drop { !$0.arguments.contains("run") }.filter { $0.arguments.first == "ls" }
    #expect(probesAfterSplit.count == 3)
  }

  @Test func countsSlowProbesAgainstTheStartupWindow() throws {
    let clock = FakeClock()
    let base = try responder(browsersJSON: Data(#"{"browsers":[]}"#.utf8), tty: "ttys009")
    let runner = FakeRunner { executable, arguments in
      if arguments.first == "ls" { clock.advance(1) }
      return base(executable, arguments)
    }
    let opener = PaneOpener(
      runner: runner, rexPath: rex, command: .terminalBrowser(path: terminalBrowser), startupWindow: 3, now: clock.now,
      sleep: clock.advance)
    _ = try opener.open(link, lastFocusedSession: "session:focused")
    let probesAfterSplit = runner.calls.drop { !$0.arguments.contains("run") }.filter { $0.arguments.first == "ls" }
    #expect(probesAfterSplit.count == 3)
  }

  @Test func reportsTheSplitEvenWhenProbingForTheNewBrowserFails() throws {
    let split = LockedFlag()
    let base = try responder(browsersJSON: Data(#"{"browsers":[]}"#.utf8), tty: "ttys009")
    let runner = ThrowingAfterSplitRunner(base: base, split: split)
    let outcome = try opener(runner.fake).open(link, lastFocusedSession: "session:focused")
    #expect(outcome == .split(PaneTarget(session: "session:focused", window: "window:active", block: "block:shell")))
  }

  @Test func splitsWhenListingTheWindowsPanesFails() throws {
    let runner = FakeRunner(
      try responder(
        browsersJSON: try fixture("terminal-browser-ls"), tty: "ttys009",
        overrides: ["block ls": CommandResult(status: 1)]))
    #expect(
      try opener(runner).open(link, lastFocusedSession: "session:focused")
        == .split(
          PaneTarget(session: "session:focused", window: "window:active", block: "block:shell")))
  }

  @Test func opensATabInABrowserAlreadyInTheWindow() throws {
    let runner = FakeRunner(try responder(browsersJSON: try fixture("terminal-browser-ls"), tty: "ttys009"))
    let outcome = try opener(runner).open(link, lastFocusedSession: "session:focused")
    #expect(outcome == .newTab(browser: "50273-6"))
    #expect(
      runner.calls.contains(
        .init(executable: terminalBrowser, arguments: newTabArguments(browser: "50273-6", url: link))))
    #expect(runner.calls.allSatisfy { !$0.arguments.contains("run") })
  }

  @Test func focusesTheBrowserPaneAfterOpeningATab() throws {
    let runner = FakeRunner(try responder(browsersJSON: try fixture("terminal-browser-ls"), tty: "ttys009"))
    _ = try opener(runner).open(link, lastFocusedSession: "session:focused")
    #expect(
      runner.calls.last
        == .init(executable: rex, arguments: focusArguments(session: "session:focused", block: "block:shell")))
  }

  @Test func keepsTheTabWhenFocusingTheBrowserPaneFails() throws {
    let runner = FakeRunner(
      try responder(
        browsersJSON: try fixture("terminal-browser-ls"), tty: "ttys009",
        overrides: ["focus --session": CommandResult(status: 1)]))
    #expect(try opener(runner).open(link, lastFocusedSession: "session:focused") == .newTab(browser: "50273-6"))
  }

  @Test func focusesTheNewSplit() {
    let arguments = splitArguments(
      target: PaneTarget(session: "s", window: "w", block: "b"), url: link,
      command: .terminalBrowser(path: terminalBrowser))
    #expect(!arguments.contains { $0.hasPrefix("--focus") })
  }

  @Test func onlyInspectsBlocksInTheFocusedWindow() throws {
    let runner = FakeRunner(try responder(browsersJSON: try fixture("terminal-browser-ls"), tty: "ttys009"))
    _ = try opener(runner).open(link, lastFocusedSession: "session:focused")
    let inspected = runner.calls.filter { $0.arguments.contains("call") }.compactMap { call in
      call.arguments.firstIndex(of: "--block").map { call.arguments[$0 + 1] }
    }
    #expect(inspected == ["block:shell", "block:browser", "block:preview"])
  }

  @Test func splitsRightOfTheFocusedPaneWhenNoBrowserIsInTheWindow() throws {
    let runner = FakeRunner(try responder(browsersJSON: try fixture("terminal-browser-ls"), tty: "ttys001"))
    let outcome = try opener(runner).open(link, lastFocusedSession: "session:focused")
    let target = PaneTarget(session: "session:focused", window: "window:active", block: "block:shell")
    #expect(outcome == .split(target))
    #expect(
      splitCall(runner)
        == .init(
          executable: rex,
          arguments: splitArguments(target: target, url: link, command: .terminalBrowser(path: terminalBrowser))))
  }

  @Test func splitsWithoutInspectingPanesWhenNoBrowserIsRunning() throws {
    let runner = FakeRunner(try responder(browsersJSON: Data(#"{"browsers":[]}"#.utf8), tty: "ttys009"))
    _ = try opener(runner).open(link, lastFocusedSession: "session:focused")
    #expect(runner.calls.allSatisfy { !$0.arguments.contains("call") && $0.executable != "/bin/ps" })
    #expect(splitCall(runner) != nil)
  }

  @Test func splitsWhenListingBrowsersFails() throws {
    let runner = FakeRunner(
      try responder(
        browsersJSON: Data(), tty: "ttys009", overrides: ["ls --all": CommandResult(status: 1)]))
    #expect(
      try opener(runner).open(link, lastFocusedSession: nil)
        == .split(
          PaneTarget(session: "session:first", window: "window:active", block: "block:shell")))
  }

  @Test func failsWhenNoAppIsAttached() throws {
    let runner = FakeRunner(
      try responder(
        browsersJSON: Data(), tty: "", overrides: ["client ls": ok(#"{"clients":[]}"#)]))
    #expect(throws: OpenError.self) { try opener(runner).open(link, lastFocusedSession: nil) }
  }

  @Test func failsWhenTheSessionHasNoFocusedPane() throws {
    let runner = FakeRunner(
      try responder(
        browsersJSON: Data(), tty: "", overrides: ["session inspect": ok(#"{"windows":[]}"#)]))
    #expect(throws: OpenError.self) { try opener(runner).open(link, lastFocusedSession: nil) }
  }

  @Test func failsWhenTheSplitFails() throws {
    let runner = FakeRunner(
      try responder(
        browsersJSON: Data(#"{"browsers":[]}"#.utf8), tty: "",
        overrides: ["run --session": CommandResult(status: 1, stderr: Data("no such block".utf8))]))
    #expect(throws: OpenError("rex run exited with 1: no such block")) {
      try opener(runner).open(link, lastFocusedSession: "session:focused")
    }
  }

  @Test func failsWhenNewTabFails() throws {
    let runner = FakeRunner(
      try responder(
        browsersJSON: try fixture("terminal-browser-ls"), tty: "ttys009",
        overrides: ["new-tab --browser": CommandResult(status: 2)]))
    #expect(throws: OpenError.self) { try opener(runner).open(link, lastFocusedSession: "session:focused") }
  }

  @Test func neverAutostartsTheRexServer() throws {
    let runner = FakeRunner(try responder(browsersJSON: try fixture("terminal-browser-ls"), tty: "ttys009"))
    _ = try opener(runner).open(link, lastFocusedSession: "session:focused")
    let rexCalls = runner.calls.filter { $0.executable == rex }
    #expect(!rexCalls.isEmpty)
    #expect(rexCalls.allSatisfy { $0.arguments.first == "--autostart=false" })
  }

  @Test func passesTheURLAsOneArgument() {
    let target = PaneTarget(session: "s", window: "w", block: "b")
    let arguments = splitArguments(target: target, url: link, command: .terminalBrowser(path: terminalBrowser))
    #expect(Array(arguments.suffix(4)) == ["--", terminalBrowser, "open", link.absoluteString])
    #expect(newTabArguments(browser: "k", url: link) == ["new-tab", "--browser", "k", link.absoluteString])
  }
}

struct NonTabBrowserOpenerTests {
  @Test func splitsTextBrowsersWithoutLookingForTerminalBrowser() throws {
    let clients = try fixture("client-ls")
    let inspect = try fixture("session-inspect")
    let runner = FakeRunner { executable, arguments in
      let command = arguments.filter { $0 != "--autostart=false" }.prefix(2).joined(separator: " ")
      switch command {
      case "client ls": return ok(clients)
      case "session inspect": return ok(inspect)
      case "run --session": return ok("{}")
      default: return CommandResult(status: 99, stderr: Data("unexpected \(executable) \(arguments)".utf8))
      }
    }
    let command = PaneCommand.direct(name: "w3m", path: "/opt/w3m")
    let link = URL(string: "https://example.com")!
    let opener = PaneOpener(runner: runner, rexPath: "/opt/rex", command: command)
    let target = PaneTarget(session: "session:focused", window: "window:active", block: "block:shell")

    #expect(try opener.open(link, lastFocusedSession: "session:focused") == .split(target))
    #expect(runner.calls.count == 3)
    #expect(runner.calls.last?.arguments == splitArguments(target: target, url: link, command: command))
  }
}
