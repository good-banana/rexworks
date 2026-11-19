import Foundation
import SideclickCore
import Testing

struct BrowserChoiceTests {
  @Test(arguments: [
    BrowserChoice.builtIn(.terminalBrowser), .builtIn(.w3m), .builtIn(.lynx), .custom(command: "carbonyl {url}"),
  ])
  func roundTripsThroughConfig(browser: BrowserChoice) throws {
    let config = Config(rexPath: "/opt/rex", browser: browser, browserPath: "/opt/b", previousHandlers: [:])
    #expect(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config)) == config)
  }

  @Test func defaultsToTerminalBrowserWhenTheConfigHasNoBrowser() throws {
    let data = Data(#"{"rexPath":"/opt/rex","previousHandlers":{"https":"com.brave.browser"}}"#.utf8)
    let config = try JSONDecoder().decode(Config.self, from: data)
    #expect(config.browser == .builtIn(.terminalBrowser))
    #expect(config.browserPath == nil)
  }

  @Test func rejectsAnUnknownBrowserInTheConfig() {
    let data = Data(#"{"rexPath":"/opt/rex","browser":{"name":"netscape"}}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Config.self, from: data) }
  }

  @Test func parsesBuiltInNames() throws {
    #expect(try BrowserChoice.parse(["w3m"]).get() == .builtIn(.w3m))
    #expect(try BrowserChoice.parse(["terminal-browser"]).get() == .builtIn(.terminalBrowser))
  }

  @Test func parsesACustomCommandWithAPlaceholder() throws {
    #expect(try BrowserChoice.parse(["custom", " carbonyl {url} "]).get() == .custom(command: "carbonyl {url}"))
  }

  @Test(arguments: [["custom", "carbonyl"], ["netscape"], ["custom"], ["w3m", "extra"], []])
  func rejectsInvalidChoices(arguments: [String]) {
    #expect(throws: OpenError.self) { try BrowserChoice.parse(arguments).get() }
  }
}

struct PaneCommandTests {
  let target = PaneTarget(session: "s", window: "w", block: "b")
  let link = URL(string: "https://example.com/page?q=1")!

  @Test func resolvesBuiltInsWithTheirPath() throws {
    #expect(
      try PaneCommand.resolve(browser: .builtIn(.terminalBrowser), browserPath: "/opt/tb")
        == .terminalBrowser(path: "/opt/tb"))
    #expect(
      try PaneCommand.resolve(browser: .builtIn(.lynx), browserPath: "/opt/lynx")
        == .direct(name: "lynx", path: "/opt/lynx"))
    #expect(
      try PaneCommand.resolve(browser: .custom(command: "x {url}"), browserPath: nil) == .custom(command: "x {url}"))
  }

  @Test func refusesABuiltInWithoutAPath() {
    #expect(throws: OpenError.self) { try PaneCommand.resolve(browser: .builtIn(.w3m), browserPath: nil) }
    #expect(throws: OpenError.self) { try PaneCommand.resolve(browser: .builtIn(.w3m), browserPath: "") }
  }

  @Test func splitsTextBrowsersWithoutAShell() {
    let arguments = splitArguments(target: target, url: link, command: .direct(name: "w3m", path: "/opt/w3m"))
    #expect(Array(arguments.suffix(4)) == ["--shell=none", "--", "/opt/w3m", link.absoluteString])
    #expect(arguments.contains("w3m"))
  }

  @Test func passesTheURLToCustomCommandsAsAnArgument() {
    let arguments = splitArguments(target: target, url: link, command: .custom(command: "carbonyl {url}"))
    #expect(Array(arguments.suffix(6)) == ["--", "/bin/sh", "-c", #"carbonyl "$1""#, "sideclick", link.absoluteString])
    #expect(!arguments.contains("--shell=none"))
  }

  @Test(arguments: ["open {url}", "open '{url}'", "open \"{url}\""])
  func quotesThePlaceholderExactlyOnce(command: String) {
    #expect(customShellScript(command) == #"open "$1""#)
  }

  @Test func customCommandsReceiveHostileURLsVerbatim() throws {
    let hostile = #"https://e.com/?a=$(touch /tmp/sideclick-pwned)&b=`id`&c='"; echo injected"#
    let result = try ProcessRunner().run("/bin/sh", ["-c", customShellScript("printf %s {url}"), "sideclick", hostile])
    #expect(result.status == 0)
    #expect(String(decoding: result.stdout, as: UTF8.self) == hostile)
    #expect(!FileManager.default.fileExists(atPath: "/tmp/sideclick-pwned"))
  }
}

struct AvailabilityCheckTests {
  final class Recorder: @unchecked Sendable {
    var asked: [String] = []
    var brewRuns: [[String]] = []
    var installed = false
  }

  func check(
    _ recorder: Recorder, found: Bool = false, brew: Bool = true, interactive: Bool = true, answer: Bool = true,
    brewStatus: Int32 = 0, installs: Bool = true
  ) -> AvailabilityCheck {
    AvailabilityCheck(
      find: { name in
        if name == "brew" { return brew ? "/opt/homebrew/bin/brew" : nil }
        return found || recorder.installed ? "/opt/homebrew/bin/\(name)" : nil
      },
      interactive: interactive,
      ask: { prompt in
        recorder.asked.append(prompt)
        return answer
      },
      runBrew: { _, arguments in
        recorder.brewRuns.append(arguments)
        if brewStatus == 0, installs { recorder.installed = true }
        return brewStatus
      },
      say: { _ in })
  }

  @Test func usesAnInstalledBrowserWithoutAsking() throws {
    let recorder = Recorder()
    #expect(try check(recorder, found: true).ensure(.terminalBrowser).get() == "/opt/homebrew/bin/terminal-browser")
    #expect(recorder.asked.isEmpty)
    #expect(recorder.brewRuns.isEmpty)
  }

  @Test func installsWithConsent() throws {
    let recorder = Recorder()
    #expect(try check(recorder).ensure(.terminalBrowser).get() == "/opt/homebrew/bin/terminal-browser")
    #expect(recorder.asked.count == 1)
    #expect(recorder.asked[0].contains("brew install --cask terminal-browser"))
    #expect(recorder.brewRuns == [["install", "--cask", "terminal-browser"]])
  }

  @Test func usesTheFormulaForTextBrowsers() throws {
    let recorder = Recorder()
    _ = try check(recorder).ensure(.lynx).get()
    #expect(recorder.brewRuns == [["install", "lynx"]])
  }

  @Test func stopsWhenDeclined() {
    let recorder = Recorder()
    #expect(throws: OpenError.self) { try check(recorder, answer: false).ensure(.w3m).get() }
    #expect(recorder.brewRuns.isEmpty)
  }

  @Test func stopsWithoutAskingWhenNotInteractive() {
    let recorder = Recorder()
    #expect(throws: OpenError.self) { try check(recorder, interactive: false).ensure(.w3m).get() }
    #expect(recorder.asked.isEmpty)
    #expect(recorder.brewRuns.isEmpty)
  }

  @Test func pointsToTheWebsiteWithoutHomebrew() {
    let recorder = Recorder()
    let result = check(recorder, brew: false).ensure(.terminalBrowser)
    #expect(throws: OpenError.self) { try result.get() }
    if case .failure(let error) = result { #expect(error.description.contains("https://terminal-browser.com")) }
    #expect(recorder.asked.isEmpty)
  }

  @Test func stopsWhenTheInstallFails() {
    let recorder = Recorder()
    #expect(throws: OpenError.self) { try check(recorder, brewStatus: 1).ensure(.w3m).get() }
  }

  @Test func stopsWhenTheInstallLeavesTheBrowserMissing() {
    let recorder = Recorder()
    #expect(throws: OpenError.self) { try check(recorder, installs: false).ensure(.w3m).get() }
  }

  @Test(arguments: [("y", true), ("YES", true), (" yes ", true), ("n", false), ("", false), (nil, false)])
  func readsYesAnswers(answer: String?, expected: Bool) {
    #expect(isYes(answer) == expected)
  }
}

struct BundledAppTests {
  @Test func findsTheAppNextToASymlinkedExecutable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cellarBin = root.appendingPathComponent("Cellar/sideclick/0.1.0/bin", isDirectory: true)
    let linkDirectory = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: cellarBin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
    let executable = cellarBin.appendingPathComponent("sideclick")
    FileManager.default.createFile(atPath: executable.path, contents: Data())
    let link = linkDirectory.appendingPathComponent("sideclick")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)

    let candidates = bundledAppCandidates(executable: link)
    let expected = root.appendingPathComponent("Cellar/sideclick/0.1.0/libexec/Sideclick.app").resolvingSymlinksInPath()
    #expect(candidates.first?.resolvingSymlinksInPath().path == expected.path)
  }
}

struct HomebrewInstallTests {
  @Test(arguments: [
    ("/opt/homebrew/Cellar/sideclick/0.1.0/bin/sideclick", true),
    ("/usr/local/Cellar/sideclick/0.2.0/bin/sideclick", true),
    ("/opt/homebrew/Cellar/other/1.0/bin/sideclick", false),
    ("/Users/someone/rexworks/sideclick/.build/debug/sideclick", false),
    ("/opt/homebrew/Cellar", false),
  ])
  func detectsTheSideclickKeg(path: String, expected: Bool) {
    #expect(installedByHomebrew(executable: URL(fileURLWithPath: path)) == expected)
  }
}
