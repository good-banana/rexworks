import Foundation
import SideclickCore

let usage = """
  Usage: sideclick <command> [arguments]

  Commands:
    setup [--app <path>]  Install the handler app, check for the in-pane browser, and make
                          Sideclick the default for web links. --app installs a development build.
    config                Show the in-pane browser
    config get browser
    config set browser <terminal-browser | w3m | lynx>
    config set browser custom '<command with {url}>'
    config unset browser  Go back to terminal-browser
    uninstall             Restore the previous browser and remove Sideclick, including its Homebrew formula
    doctor                Diagnose the installation
    -v, --version         Print the version
    --help                Show this help
  """

let paths = SupportPaths(home: FileManager.default.homeDirectoryForCurrentUser)
let registry = SystemHandlerRegistry()
let searchPath = ProcessInfo.processInfo.environment["PATH"]

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("sideclick: \(message)\n".utf8))
  exit(1)
}

func loadConfig() -> Config? {
  do {
    return try ConfigStore.load(paths)
  } catch {
    fail("cannot read \(paths.configFile.path): \(error.localizedDescription)")
  }
}

func save(_ config: Config) {
  do {
    try ConfigStore.save(config, paths)
  } catch {
    fail("cannot write \(paths.configFile.path): \(error.localizedDescription)")
  }
}

func availabilityCheck() -> AvailabilityCheck {
  AvailabilityCheck(
    find: { findBrowserExecutable($0, path: searchPath) },
    interactive: isatty(STDIN_FILENO) == 1,
    ask: { prompt in
      print(prompt, terminator: "")
      fflush(stdout)
      return isYes(readLine())
    },
    runBrew: { brew, arguments in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: brew)
      process.arguments = arguments
      do {
        try process.run()
      } catch {
        return -1
      }
      process.waitUntilExit()
      return process.terminationStatus
    },
    say: { print($0) })
}

func resolvedPath(for browser: BrowserChoice) -> String? {
  guard case .builtIn(let builtIn) = browser else { return nil }
  switch availabilityCheck().ensure(builtIn) {
  case .success(let path): return path
  case .failure(let error): fail(error.description)
  }
}

func findRex() -> String {
  guard let rex = findExecutable("rex", path: searchPath) else {
    fail("rex is not on PATH; install Rex from https://www.superlogical.com/rex")
  }
  return rex
}

func bundledApp(_ arguments: [String]) -> URL {
  switch arguments {
  case []:
    let executable = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: nil)
    let candidates = bundledAppCandidates(executable: Bundle.main.executableURL ?? executable)
    guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
      fail("cannot find the bundled Sideclick.app (looked in \(candidates.map(\.path).joined(separator: ", ")))")
    }
    return found
  case let options where options.count == 2 && options[0] == "--app":
    let app = URL(fileURLWithPath: options[1]).standardizedFileURL
    guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
      fail("\(app.path) is not an app bundle")
    }
    return app
  default:
    fail("usage: sideclick setup [--app <path>]")
  }
}

func installApp(from source: URL) {
  let fileManager = FileManager.default
  let destination = paths.app.standardizedFileURL
  guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else { return }
  _ = try? ProcessRunner().run("/usr/bin/pkill", ["-x", "SideclickHandler"])
  do {
    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
    try fileManager.copyItem(at: source, to: destination)
  } catch {
    fail("cannot install \(destination.path): \(error.localizedDescription)")
  }
}

func setup(_ arguments: [String]) async {
  let source = bundledApp(arguments)
  let existing = loadConfig()
  let browser = existing?.browser ?? .default
  let browserPath = resolvedPath(for: browser)
  let rex = findRex()

  installApp(from: source)
  let current = Dictionary(uniqueKeysWithValues: webSchemes.map { ($0, registry.defaultHandler(forScheme: $0)) })
  let previous = recordPreviousHandlers(existing: existing?.previousHandlers ?? [:], current: current)
  save(Config(rexPath: rex, browser: browser, browserPath: browserPath, previousHandlers: previous))
  do {
    try registry.register(app: paths.app)
  } catch {
    fail("\(error)")
  }
  print("recorded previous browser: \(previous.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
  for scheme in webSchemes where registry.defaultHandler(forScheme: scheme) != routerBundleID {
    print("setting the default for \(scheme) links; confirm the macOS prompt")
    do {
      try await registry.setDefaultHandler(paths.app, forScheme: scheme)
    } catch {
      fail(
        "cannot become the default for \(scheme) links (\(error.localizedDescription)); "
          + "if you chose to keep your current browser in the macOS prompt, rerun sideclick setup and choose Sideclick")
    }
  }
  for scheme in webSchemes {
    let handler = registry.defaultHandler(forScheme: scheme) ?? "none"
    guard handler == routerBundleID else { fail("\(scheme) links still open with \(handler)") }
  }
  print("web links Cmd-clicked in Rex now open in \(browser.label); hold Option to use your previous browser")
}

func setBrowser(_ browser: BrowserChoice) {
  let browserPath = resolvedPath(for: browser)
  var config = loadConfig() ?? Config(rexPath: findRex(), browserPath: nil, previousHandlers: [:])
  config.browser = browser
  config.browserPath = browserPath
  save(config)
  print("browser: \(browser.description)")
}

func configCommand(_ arguments: [String]) {
  switch arguments {
  case [], ["get", "browser"]:
    print("browser: \((loadConfig()?.browser ?? .default).description)")
  case let options where options.count >= 3 && options[0] == "set" && options[1] == "browser":
    switch BrowserChoice.parse(Array(options.dropFirst(2))) {
    case .success(let browser): setBrowser(browser)
    case .failure(let error): fail(error.description)
    }
  case ["unset", "browser"]:
    setBrowser(.default)
  default:
    fail("usage: sideclick config [get browser | set browser <name> | unset browser]")
  }
}

func uninstall() async {
  let config: Config?
  do {
    config = try ConfigStore.load(paths)
  } catch {
    config = nil
    print("cannot read \(paths.configFile.path): \(error.localizedDescription); restoring Safari")
  }
  for step in restorePlan(previous: config?.previousHandlers ?? [:], isInstalled: registry.isInstalled) {
    if let missing = step.missingPrevious { print("\(missing) is no longer installed; using \(step.bundleID)") }
    guard registry.defaultHandler(forScheme: step.scheme) == routerBundleID else { continue }
    guard let app = registry.applicationURL(for: step.bundleID) else { fail("cannot find \(step.bundleID)") }
    print("restoring \(step.bundleID) for \(step.scheme) links; confirm the macOS prompt")
    do {
      try await registry.setDefaultHandler(app, forScheme: step.scheme)
    } catch {
      fail(
        "cannot restore \(step.bundleID) for \(step.scheme) links (\(error.localizedDescription)); "
          + "if you chose to keep Sideclick in the macOS prompt, rerun sideclick uninstall and choose \(step.bundleID)")
    }
  }
  let fileManager = FileManager.default
  _ = try? ProcessRunner().run("/usr/bin/pkill", ["-x", "SideclickHandler"])
  if fileManager.fileExists(atPath: paths.app.path) {
    try? registry.unregister(app: paths.app)
    do {
      try fileManager.removeItem(at: paths.app)
    } catch {
      fail("cannot remove \(paths.app.path): \(error.localizedDescription)")
    }
  }
  if fileManager.fileExists(atPath: paths.root.path) {
    do {
      try fileManager.removeItem(at: paths.root)
    } catch {
      fail("cannot remove \(paths.root.path): \(error.localizedDescription)")
    }
  }
  print("removed Sideclick and restored your previous browser")
  removeHomebrewFormula()
}

func removeHomebrewFormula() {
  let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
  guard installedByHomebrew(executable: executable) else { return }
  guard let brew = findBrowserExecutable("brew", path: searchPath) else {
    return print("run `brew uninstall sideclick` to remove the command")
  }
  print("removing the sideclick command with brew uninstall sideclick")
  let process = Process()
  process.executableURL = URL(fileURLWithPath: brew)
  process.arguments = ["uninstall", "sideclick"]
  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return print(
      "cannot run brew (\(error.localizedDescription)); run `brew uninstall sideclick` to remove the command")
  }
  if process.terminationStatus != 0 { print("run `brew uninstall sideclick` to remove the command") }
}

func doctor() {
  var healthy = true
  func report(_ ok: Bool, _ message: String) {
    print("\(ok ? "ok  " : "FAIL") \(message)")
    if !ok { healthy = false }
  }
  report(FileManager.default.fileExists(atPath: paths.app.path), "app at \(paths.app.path)")
  report(registry.isInstalled(routerBundleID), "app registered with Launch Services")
  for scheme in webSchemes {
    let handler = registry.defaultHandler(forScheme: scheme) ?? "none"
    report(handler == routerBundleID, "default handler for \(scheme) is \(handler)")
  }
  let config: Config?
  do {
    config = try ConfigStore.load(paths)
  } catch {
    config = nil
  }
  guard let config else { return report(false, "config at \(paths.configFile.path)") }
  for scheme in webSchemes {
    let previous = config.previousHandlers[scheme] ?? "none"
    report(registry.isInstalled(previous), "previous handler for \(scheme) is \(previous)")
  }
  report(FileManager.default.isExecutableFile(atPath: config.rexPath), "rex at \(config.rexPath)")
  switch config.browser {
  case .builtIn(let browser):
    let path = config.browserPath ?? "none"
    report(FileManager.default.isExecutableFile(atPath: path), "browser \(browser.name) at \(path)")
  case .custom(let command):
    report(command.contains(urlPlaceholder), "browser custom command: \(command)")
  }
  let whoami = try? ProcessRunner().run(config.rexPath, ["--autostart=false", "whoami", "--json"])
  report(whoami?.status == 0, "rex whoami responds")
  if !healthy { exit(1) }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "setup": await setup(Array(arguments.dropFirst()))
case "config": configCommand(Array(arguments.dropFirst()))
case "uninstall" where arguments.count == 1: await uninstall()
case "doctor" where arguments.count == 1: doctor()
case "--version", "-v": print(sideclickVersion)
case "--help", "-h", nil: print(usage)
default:
  FileHandle.standardError.write(Data("\(usage)\n".utf8))
  exit(64)
}
