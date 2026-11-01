import AppKit
import Foundation

public protocol PreferenceReading {
  func value(forKey key: String, domain: String) -> Any?
}

public protocol ThemeFileAccessing {
  func applicationURL(bundleID: String) -> URL?
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

  public func applicationURL(bundleID: String) -> URL? {
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

  public var colors: TerminalColorSet
  public var source: Source

  public var palette: RenderPalette { RenderPalette(colors: colors) }
}

public struct ThemeResolver {
  public static let rexBundleID = "com.superlogical.rex"
  static let themesPath = "Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json"

  public var runner: ProcessRunning
  public var preferences: PreferenceReading
  public var files: ThemeFileAccessing
  public var rexPath: String?
  public var environment: [String: String]

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

  public func resolve(inBand: TerminalColorSet) -> ResolvedTheme {
    guard let rexPalette = rexAPIPalette() else {
      return ResolvedTheme(colors: inBand, source: .terminalQuery)
    }
    let scheme = colorScheme(inBand: inBand)
    let themes = availableThemes()
    let themeID = preferences.value(
      forKey: scheme == .dark ? "Workspace.darkThemeID" : "Workspace.lightThemeID", domain: Self.rexBundleID)
    if let themeID = themeID as? String,
      let theme = themes.first(where: { $0.id == themeID }),
      matches(theme, rexPalette)
    {
      return ResolvedTheme(colors: colors(theme, rexPalette, scheme), source: .rexTheme(theme.id))
    }
    let candidates = themes.filter { matches($0, rexPalette) }
    if let theme = candidates.first(where: { $0.appearance == scheme }) ?? candidates.first {
      return ResolvedTheme(colors: colors(theme, rexPalette, scheme), source: .rexPaletteMatch(theme.id))
    }
    var colors = inBand
    colors.palette = rexPalette
    return ResolvedTheme(colors: colors, source: .rexPalette)
  }

  func colorScheme(inBand: TerminalColorSet) -> ColorScheme {
    if let scheme = inBand.colorScheme { return scheme }
    switch preferences.value(forKey: "Workspace.appearance", domain: Self.rexBundleID) as? String {
    case "dark": return .dark
    case "light": return .light
    default:
      let style = preferences.value(forKey: "AppleInterfaceStyle", domain: kCFPreferencesAnyApplication as String)
      return (style as? String)?.lowercased() == "dark" ? .dark : .light
    }
  }

  func availableThemes() -> [RexTheme] {
    let custom = parseRexThemes(preferences.value(forKey: "Workspace.customThemes", domain: Self.rexBundleID))
    guard let app = files.applicationURL(bundleID: Self.rexBundleID),
      let data = files.contents(of: app.appendingPathComponent(Self.themesPath))
    else { return custom }
    return custom + parseRexThemes(data)
  }

  func rexAPIPalette() -> [RGB?]? {
    guard let rexPath, let session = environment["REX_SESSION"], let block = environment["REX_BLOCK"],
      let result = try? runner.run(
        rexPath,
        [
          "do", "com.superlogical.terminal.format", "-s", session, "-b", block, "format=vt", "extra_palette=true",
          "max_bytes=8192", "--json",
        ]),
      result.status == 0,
      let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
      let content = json["content"] as? String
    else { return nil }
    var reader = TerminalColorReplyReader(expectsPalette: true)
    reader.feed(Array(content.utf8))
    return reader.colors.palette.contains(nil) ? nil : reader.colors.palette
  }

  private func matches(_ theme: RexTheme, _ palette: [RGB?]) -> Bool {
    zip(theme.ansi, palette).allSatisfy { $0.description == $1?.description }
  }

  private func colors(_ theme: RexTheme, _ palette: [RGB?], _ scheme: ColorScheme) -> TerminalColorSet {
    TerminalColorSet(
      foreground: theme.foreground, background: theme.background, palette: palette,
      colorScheme: theme.appearance ?? scheme, cursor: theme.cursor, selectionBackground: theme.selectionBackground)
  }
}
