import AppKit
import Foundation

public protocol PreferenceReading {
  func value(forKey key: String, domain: String) -> Any?
}

public struct RunningApplication: Equatable, Sendable {
  public var pid: Int32
  public var bundleURL: URL

  public init(pid: Int32, bundleURL: URL) {
    self.pid = pid
    self.bundleURL = bundleURL
  }
}

public protocol ThemeFileAccessing {
  func runningApplications(bundleID: String) -> [RunningApplication]
  func installedApplicationURL(bundleID: String) -> URL?
  func contents(of url: URL) -> Data?
}

public struct SystemPreferenceReader: PreferenceReading {
  public init() {}

  public func value(forKey key: String, domain: String) -> Any? {
    CFPreferencesAppSynchronize(domain as CFString)
    return CFPreferencesCopyAppValue(key as CFString, domain as CFString)
  }
}

public struct SystemThemeFileAccess: ThemeFileAccessing {
  public init() {}

  public func runningApplications(bundleID: String) -> [RunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).compactMap { app in
      app.bundleURL.map { RunningApplication(pid: app.processIdentifier, bundleURL: $0) }
    }
  }

  public func installedApplicationURL(bundleID: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
  }

  public func contents(of url: URL) -> Data? {
    try? Data(contentsOf: url)
  }
}

public struct RexTheme: Equatable, Sendable {
  public var id: String
  public var appearance: ColorScheme?
  public var background: RGB
  public var foreground: RGB
  public var cursor: RGB?
  public var selectionBackground: RGB?
  public var ansi: [RGB]

  init?(_ entry: [String: Any]) {
    guard let id = entry["id"] as? String else { return nil }
    let source = entry["source"] as? [String: Any] ?? entry
    guard let background = (source["background"] as? String).flatMap(parseHexColor),
      let foreground = (source["foreground"] as? String).flatMap(parseHexColor)
    else { return nil }
    let ansiStrings: [String?]
    if let list = source["ansi"] as? [Any] {
      ansiStrings = list.map { $0 as? String }
    } else if let map = source["ansi"] as? [String: Any] {
      ansiStrings = (0..<TerminalColorSet.paletteSize).map { map[String($0)] as? String }
    } else {
      return nil
    }
    let ansi = ansiStrings.prefix(TerminalColorSet.paletteSize).compactMap { $0.flatMap(parseHexColor) }
    guard ansi.count == TerminalColorSet.paletteSize else { return nil }
    self.id = id
    appearance =
      switch entry["appearance"] as? String {
      case "dark": .dark
      case "light": .light
      default: nil
      }
    self.background = background
    self.foreground = foreground
    cursor = (source["cursor"] as? String).flatMap(parseHexColor)
    selectionBackground = (source["selectionBackground"] as? String).flatMap(parseHexColor)
    self.ansi = ansi
  }
}

public func parseHexColor(_ text: String) -> RGB? {
  var digits = Substring(text.trimmingCharacters(in: .whitespaces))
  if digits.hasPrefix("#") { digits = digits.dropFirst() }
  if digits.count == 3 { digits = Substring(digits.flatMap { [$0, $0] }) }
  guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
  return RGB(hex: value)
}

public func parseRexThemes(_ value: Any?) -> [RexTheme] {
  var object = value
  if let string = object as? String { object = Data(string.utf8) }
  if let data = object as? Data { object = try? JSONSerialization.jsonObject(with: data) }
  if let wrapper = object as? [String: Any] {
    object = wrapper["themes"] ?? Array(wrapper.values)
  }
  return (object as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(RexTheme.init) }
}

public struct ResolvedTheme: Equatable, Sendable {
  public enum Source: Equatable, Sendable {
    case rexTheme(String)
    case rexPaletteMatch(String)
    case rexPalette
    case terminalQuery
  }

  public enum CrossCheck: Equatable, Sendable {
    case confirmed(block: String)
    case mismatch(block: String)
    case skipped
  }

  public var colors: TerminalColorSet
  public var source: Source
  public var themePalette: [RGB]?

  public init(colors: TerminalColorSet, source: Source, themePalette: [RGB]? = nil) {
    self.colors = colors
    self.source = source
    self.themePalette = themePalette
  }

  public var palette: RenderPalette { RenderPalette(colors: colors) }

  public func note(for check: CrossCheck) -> String? {
    guard case .rexTheme(let id) = source, case .mismatch(let block) = check else { return nil }
    return "theme \(id) does not match the palette of \(block); using the theme colors"
  }
}

public struct ThemeResolver {
  public static let rexBundleIDs = ["com.superlogical.rex"]
  static let preferencesDomain = "com.superlogical.rex"
  static let themesPath = "Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json"
  static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh"]
  static let maximumShellProbes = 8

  public var runner: ProcessRunning
  public var preferences: PreferenceReading
  public var files: ThemeFileAccessing
  public var rexPath: String?
  public var environment: [String: String]
  public var budget: TimeInterval = 0.3
  public var crossCheckBudget: TimeInterval = 2

  public init(
    runner: ProcessRunning, preferences: PreferenceReading, files: ThemeFileAccessing, rexPath: String?,
    environment: [String: String]
  ) {
    self.runner = runner
    self.preferences = preferences
    self.files = files
    self.rexPath = rexPath
    self.environment = environment
  }

  public func resolve(inBand: TerminalColorSet, sourceBlock: String?) -> ResolvedTheme {
    guard let session = environment["REX_SESSION"] else {
      return ResolvedTheme(colors: inBand, source: .terminalQuery)
    }
    let deadline = Date().addingTimeInterval(budget)
    let scheme = colorScheme(inBand: inBand)
    let themes = availableThemes(deadline: deadline)
    let themeID = preference(scheme == .dark ? "Workspace.darkThemeID" : "Workspace.lightThemeID") as? String

    if let theme = themes.first(where: { $0.id == themeID }) {
      var resolved = ResolvedTheme(
        colors: colors(theme, scheme), source: .rexTheme(theme.id), themePalette: theme.ansi)
      if (preference("Workspace.terminalUseThemePalette") as? Bool) == false {
        let pane = sourceBlock.flatMap { apiPalette(session: session, block: $0, deadline: deadline) }
        let terminal = pane ?? inBand.palette
        resolved.colors.palette = zip(terminal, theme.ansi).map { $0 ?? $1 }
        resolved.themePalette = nil
      }
      if let selection = colorPreference(preference("Workspace.terminalSelectionBackground")) {
        resolved.colors.selectionBackground = selection
      }
      return resolved
    }

    let paneBlock = sourceBlock ?? shellBlock(session: session, deadline: deadline)
    guard let pane = paneBlock.flatMap({ apiPalette(session: session, block: $0, deadline: deadline) }) else {
      return ResolvedTheme(colors: inBand, source: .terminalQuery)
    }
    let candidates = themes.filter { matches($0.ansi, pane) }
    if let theme = candidates.first(where: { $0.appearance == scheme }) ?? candidates.first {
      return ResolvedTheme(colors: colors(theme, scheme), source: .rexPaletteMatch(theme.id))
    }
    var colors = inBand
    colors.palette = pane
    return ResolvedTheme(colors: colors, source: .rexPalette)
  }

  public func crossCheck(_ resolved: ResolvedTheme, sourceBlock: String?) -> ResolvedTheme.CrossCheck {
    guard case .rexTheme = resolved.source, let expected = resolved.themePalette,
      let session = environment["REX_SESSION"]
    else { return .skipped }
    let deadline = Date().addingTimeInterval(crossCheckBudget)
    guard let block = sourceBlock ?? shellBlock(session: session, deadline: deadline),
      let pane = apiPalette(session: session, block: block, deadline: deadline)
    else { return .skipped }
    return matches(expected, pane) ? .confirmed(block: block) : .mismatch(block: block)
  }

  func colorScheme(inBand: TerminalColorSet) -> ColorScheme {
    if let scheme = inBand.colorScheme { return scheme }
    switch preference("Workspace.appearance") as? String {
    case "dark": return .dark
    case "light": return .light
    default:
      let style = preferences.value(forKey: "AppleInterfaceStyle", domain: kCFPreferencesAnyApplication as String)
      return (style as? String)?.lowercased() == "dark" ? .dark : .light
    }
  }

  func availableThemes(deadline: Date) -> [RexTheme] {
    let custom = parseRexThemes(preference("Workspace.customThemes"))
    guard let app = rexApplicationURL(deadline: deadline),
      let data = files.contents(of: app.appendingPathComponent(Self.themesPath))
    else { return custom }
    return custom + parseRexThemes(data)
  }

  func rexApplicationURL(deadline: Date) -> URL? {
    let running = Self.rexBundleIDs.flatMap { files.runningApplications(bundleID: $0) }
    if running.count > 1, let pid = appClientPID(deadline: deadline),
      let match = running.first(where: { $0.pid == pid })
    {
      return match.bundleURL
    }
    if let first = running.first { return first.bundleURL }
    return Self.rexBundleIDs.lazy.compactMap { files.installedApplicationURL(bundleID: $0) }.first
  }

  func appClientPID(deadline: Date) -> Int32? {
    let clients = rexJSON(["client", "ls", "--json"], deadline: deadline)?["clients"] as? [[String: Any]]
    let app = clients?.first { ($0["info"] as? [String: Any])?["kind"] as? String == "app" }
    return ((app?["principal"] as? [String: Any])?["pid"] as? NSNumber)?.int32Value
  }

  func shellBlock(session: String, deadline: Date) -> String? {
    guard
      let list = rexJSON(["block", "ls", "-s", session, "--json"], deadline: deadline)?["blocks"] as? [[String: Any]]
    else { return nil }
    let candidates = list.compactMap { block -> String? in
      guard block["creator_name"] as? String == "com.superlogical.terminal",
        let id = block["block_id"] as? String, id != environment["REX_BLOCK"]
      else { return nil }
      return id
    }
    return candidates.prefix(Self.maximumShellProbes).first { id in
      let process = rexJSON(
        ["do", "com.superlogical.terminal.process", "-s", session, "-b", id, "--json"], deadline: deadline)
      let name = (process?["foreground"] as? [String: Any])?["name"] as? String
      return name.map { Self.shellNames.contains($0) } ?? false
    }
  }

  func apiPalette(session: String, block: String, deadline: Date) -> [RGB?]? {
    let arguments = [
      "do", "com.superlogical.terminal.format", "-s", session, "-b", block, "format=vt", "extra_palette=true",
      "max_bytes=8192", "--json",
    ]
    guard let content = rexJSON(arguments, deadline: deadline)?["content"] as? String else { return nil }
    var reader = TerminalColorReplyReader(expectsPalette: true)
    reader.feed(Array(content.utf8))
    return reader.colors.palette.contains(nil) ? nil : reader.colors.palette
  }

  private func preference(_ key: String) -> Any? {
    preferences.value(forKey: key, domain: Self.preferencesDomain)
  }

  private func colorPreference(_ value: Any?) -> RGB? {
    if let string = value as? String { return parseHexColor(string) }
    if let data = value as? Data {
      let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
      return parseHexColor(text)
    }
    return nil
  }

  private func rexJSON(_ arguments: [String], deadline: Date) -> [String: Any]? {
    let remaining = deadline.timeIntervalSinceNow
    guard let rexPath, remaining > 0, let result = try? runner.run(rexPath, arguments, timeout: remaining),
      result.status == 0
    else { return nil }
    return try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
  }

  private func matches(_ expected: [RGB], _ palette: [RGB?]) -> Bool {
    expected.count == palette.count && zip(expected, palette).allSatisfy { $0.description == $1?.description }
  }

  private func colors(_ theme: RexTheme, _ scheme: ColorScheme) -> TerminalColorSet {
    TerminalColorSet(
      foreground: theme.foreground, background: theme.background, palette: theme.ansi,
      colorScheme: theme.appearance ?? scheme, cursor: theme.cursor, selectionBackground: theme.selectionBackground)
  }
}

public struct ThemeRefreshScheduler: Equatable, Sendable {
  public enum Trigger: Equatable, Sendable {
    case colorScheme
    case reload
  }

  public static let debounce: TimeInterval = 0.1
  public static let maximumLateReplyWait: TimeInterval = 10

  public private(set) var inFlight = false
  public private(set) var dueAt: TimeInterval?
  private var pendingColorScheme = false
  private var awaitingLateReplySince: TimeInterval?

  public init() {}

  public var sendsColorSchemeQuery: Bool { awaitingLateReplySince == nil }

  public mutating func request(_ trigger: Trigger, now: TimeInterval) {
    if trigger == .colorScheme {
      if let since = awaitingLateReplySince {
        guard now - since >= Self.maximumLateReplyWait else { return }
        awaitingLateReplySince = nil
      }
      if inFlight {
        pendingColorScheme = true
        return
      }
    }
    dueAt = now + Self.debounce
  }

  public mutating func start(now: TimeInterval) -> Bool {
    guard !inFlight, let dueAt, now >= dueAt else { return false }
    self.dueAt = nil
    inFlight = true
    return true
  }

  public mutating func finish(now: TimeInterval, queryTimedOut: Bool) {
    inFlight = false
    if queryTimedOut {
      awaitingLateReplySince = now
    } else {
      awaitingLateReplySince = nil
      if pendingColorScheme { dueAt = now + Self.debounce }
    }
    pendingColorScheme = false
  }

  public mutating func queryTimedOut(at now: TimeInterval) {
    awaitingLateReplySince = now
  }

  public mutating func deviceAttributesReceived() {
    awaitingLateReplySince = nil
  }
}
