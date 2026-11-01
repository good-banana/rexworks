import XCTest

@testable import MDViewerCore

final class ThemeResolverTests: XCTestCase {
  private final class FakeRexCLI: ProcessRunning, @unchecked Sendable {
    var palettes: [String: Data] = [:]
    var foregrounds: [String: String] = [:]
    var blocks: [String] = []
    var failing = false
    var calls: [[String]] = []

    func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: Data) {
      calls.append(arguments)
      guard !failing, executable == "/opt/rex" else { return (1, Data(), Data()) }
      let block = arguments.firstIndex(of: "-b").map { arguments[$0 + 1] }
      if arguments.starts(with: ["block", "ls"]) {
        let list = blocks.map { ["block_id": $0, "creator_name": "com.superlogical.terminal"] }
        return (0, try JSONSerialization.data(withJSONObject: ["blocks": list]), Data())
      }
      if arguments.contains("com.superlogical.terminal.process"), let block, let name = foregrounds[block] {
        return (0, try JSONSerialization.data(withJSONObject: ["foreground": ["name": name]]), Data())
      }
      if arguments.contains("com.superlogical.terminal.format"), let block, let data = palettes[block] {
        return (0, data, Data())
      }
      return (1, Data(), Data())
    }
  }

  private struct FakePreferences: PreferenceReading {
    var values: [String: Any]

    func value(forKey key: String, domain: String) -> Any? { values["\(domain) \(key)"] }
  }

  private struct FakeFiles: ThemeFileAccessing {
    var app: URL?
    var files: [String: Data]

    func applicationURL(bundleID: String) -> URL? { bundleID == ThemeResolver.rexBundleID ? app : nil }
    func contents(of url: URL) -> Data? { files[url.path] }
  }

  private let app = URL(fileURLWithPath: "/Applications/Some Rex.app")
  private let environment = ["REX_SESSION": "session:1", "REX_BLOCK": "block:2"]
  private let rexPrefs: [String: Any] = [
    "com.superlogical.rex Workspace.darkThemeID": "charcoal-atelier",
    "com.superlogical.rex Workspace.lightThemeID": "merino-light",
  ]

  private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }

  private func resolver(
    runner: FakeRexCLI, prefs: [String: Any]? = nil, app: URL?? = nil, environment: [String: String]? = nil
  ) throws -> ThemeResolver {
    let appURL = app ?? self.app
    let files = FakeFiles(
      app: appURL,
      files: [self.app.appendingPathComponent(ThemeResolver.themesPath).path: try fixture("rex-themes")])
    return ThemeResolver(
      runner: runner, preferences: FakePreferences(values: prefs ?? rexPrefs), files: files, rexPath: "/opt/rex",
      environment: environment ?? self.environment)
  }

  private func formatOutput(palette: [UInt32]) -> Data {
    let content = palette.enumerated().map { index, hex in
      let rgb = RGB(hex: hex).description.dropFirst()
      return "\u{1b}]4;\(index);rgb:\(rgb.prefix(2))/\(rgb.dropFirst(2).prefix(2))/\(rgb.suffix(2))\u{1b}\\"
    }.joined()
    return try! JSONSerialization.data(withJSONObject: ["content": content + "$ ls\r\n", "total": 9999])
  }

  private let inBandDark = TerminalColorSet(
    palette: [
      0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
      0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
    ].map { RGB(hex: $0) }, colorScheme: .dark)

  private let ghosttyDefaults: [UInt32] = [
    0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
    0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
  ]

  private func commandPaneCLI() throws -> FakeRexCLI {
    let cli = FakeRexCLI()
    cli.palettes["block:source"] = try fixture("rex-format-palette")
    cli.palettes["block:2"] = formatOutput(palette: ghosttyDefaults)
    return cli
  }

  func testCommandPaneResolvesThemeConfirmedBySourcePane() throws {
    let cli = try commandPaneCLI()
    let resolved = try resolver(runner: cli).resolve(inBand: inBandDark, sourceBlock: "block:source")
    XCTAssertEqual(resolved.source, .rexTheme("charcoal-atelier"))
    XCTAssertEqual(resolved.crossCheck, .confirmed(block: "block:source"))
    XCTAssertNil(resolved.note)
    XCTAssertEqual(resolved.colors.background, RGB(hex: 0x161616))
    XCTAssertEqual(resolved.colors.foreground, RGB(hex: 0xd6d2cc))
    XCTAssertEqual(resolved.colors.selectionBackground, RGB(hex: 0x3a3835))
    XCTAssertEqual(resolved.colors.cursor, RGB(hex: 0xe05d3a))
    XCTAssertEqual(resolved.colors.palette[0], RGB(hex: 0x222222))
    XCTAssertEqual(resolved.colors.palette[1], RGB(hex: 0xd96a4d))
    XCTAssertEqual(resolved.palette.pageBackground, RGB(hex: 0x161616))
    XCTAssertEqual(resolved.palette.text, RGB(hex: 0xd6d2cc))
    XCTAssertEqual(
      cli.calls,
      [
        [
          "do", "com.superlogical.terminal.format", "-s", "session:1", "-b", "block:source", "format=vt",
          "extra_palette=true", "max_bytes=8192", "--json",
        ]
      ])
  }

  func testMismatchKeepsThemeFileColorsAndNotes() throws {
    let cli = try commandPaneCLI()
    let resolved = try resolver(runner: cli).resolve(inBand: inBandDark, sourceBlock: "block:2")
    XCTAssertEqual(resolved.source, .rexTheme("charcoal-atelier"))
    XCTAssertEqual(resolved.crossCheck, .mismatch(block: "block:2"))
    XCTAssertEqual(resolved.colors.background, RGB(hex: 0x161616))
    XCTAssertEqual(resolved.colors.palette[0], RGB(hex: 0x222222))
    XCTAssertEqual(
      resolved.note, "theme charcoal-atelier does not match the palette of block:2; using the theme colors")
  }

  func testWithoutSourceBlockCrossChecksAShellPane() throws {
    let cli = try commandPaneCLI()
    cli.blocks = ["block:2", "block:busy", "block:source"]
    cli.foregrounds = ["block:2": "zsh", "block:busy": "vim", "block:source": "zsh"]
    let resolved = try resolver(runner: cli).resolve(inBand: inBandDark, sourceBlock: nil)
    XCTAssertEqual(resolved.source, .rexTheme("charcoal-atelier"))
    XCTAssertEqual(resolved.crossCheck, .confirmed(block: "block:source"))
    XCTAssertFalse(cli.calls.contains { $0.contains("block:2") })
  }

  func testWithoutAnyShellPaneSkipsTheCrossCheck() throws {
    let cli = try commandPaneCLI()
    cli.blocks = ["block:busy"]
    cli.foregrounds = ["block:busy": "claude"]
    let resolved = try resolver(runner: cli).resolve(inBand: inBandDark, sourceBlock: nil)
    XCTAssertEqual(resolved.source, .rexTheme("charcoal-atelier"))
    XCTAssertEqual(resolved.crossCheck, .skipped)
    XCTAssertEqual(resolved.colors.foreground, RGB(hex: 0xd6d2cc))

    cli.failing = true
    let offline = try resolver(runner: cli).resolve(inBand: inBandDark, sourceBlock: "block:source")
    XCTAssertEqual(offline.source, .rexTheme("charcoal-atelier"))
    XCTAssertEqual(offline.crossCheck, .skipped)
  }

  func testLightSchemeSelectsLightThemeID() throws {
    let merinoLight = try lightTheme()
    var inBand = inBandDark
    inBand.colorScheme = .light
    let resolved = try resolver(runner: FakeRexCLI()).resolve(inBand: inBand, sourceBlock: nil)
    XCTAssertEqual(resolved.source, .rexTheme("merino-light"))
    XCTAssertEqual(resolved.colors.background, merinoLight.background)
    XCTAssertEqual(resolved.colors.palette.map { $0! }, merinoLight.ansi)
    XCTAssertFalse(resolved.palette.dark)
  }

  func testSchemeFallsBackToRexAppearanceThenSystemAppearance() throws {
    let cli = FakeRexCLI()
    var prefs: [String: Any] = rexPrefs
    XCTAssertEqual(try resolver(runner: cli, prefs: prefs).colorScheme(inBand: TerminalColorSet()), .light)
    prefs["\(kCFPreferencesAnyApplication as String) AppleInterfaceStyle"] = "Dark"
    XCTAssertEqual(try resolver(runner: cli, prefs: prefs).colorScheme(inBand: TerminalColorSet()), .dark)
    prefs["com.superlogical.rex Workspace.appearance"] = "light"
    XCTAssertEqual(try resolver(runner: cli, prefs: prefs).colorScheme(inBand: TerminalColorSet()), .light)
    XCTAssertEqual(
      try resolver(runner: cli, prefs: prefs).colorScheme(inBand: TerminalColorSet(colorScheme: .dark)), .dark)
  }

  func testUnknownThemeIDFallsBackToPaletteMatch() throws {
    var prefs: [String: Any] = rexPrefs
    prefs["com.superlogical.rex Workspace.darkThemeID"] = "deleted-theme"
    let resolved = try resolver(runner: try commandPaneCLI(), prefs: prefs)
      .resolve(inBand: inBandDark, sourceBlock: "block:source")
    XCTAssertEqual(resolved.source, .rexPaletteMatch("charcoal-atelier"))
    XCTAssertEqual(resolved.colors.background, RGB(hex: 0x161616))
  }

  func testUnknownPaletteKeepsRexPaletteAndInBandColors() throws {
    var palette = (0..<16).map { UInt32($0 * 0x0f0f0f) }
    palette[3] = 0x123456
    let cli = FakeRexCLI()
    cli.palettes["block:source"] = formatOutput(palette: palette)
    var inBand = inBandDark
    inBand.background = RGB(hex: 0x101010)
    let resolved = try resolver(runner: cli, prefs: [:]).resolve(inBand: inBand, sourceBlock: "block:source")
    XCTAssertEqual(resolved.source, .rexPalette)
    XCTAssertEqual(resolved.colors.palette[3], RGB(hex: 0x123456))
    XCTAssertEqual(resolved.colors.background, RGB(hex: 0x101010))
    XCTAssertNil(resolved.colors.foreground)
  }

  func testMissingAppFallsBackToPaletteThenInBand() throws {
    let cli = try commandPaneCLI()
    let noApp = try resolver(runner: cli, app: .some(nil)).resolve(inBand: inBandDark, sourceBlock: "block:source")
    XCTAssertEqual(noApp.source, .rexPalette)
    XCTAssertEqual(noApp.colors.palette[1], RGB(hex: 0xd96a4d))
    XCTAssertNil(noApp.colors.background)

    let noAppNoSource = try resolver(runner: cli, app: .some(nil)).resolve(inBand: inBandDark, sourceBlock: nil)
    XCTAssertEqual(noAppNoSource, ResolvedTheme(colors: inBandDark, source: .terminalQuery))
  }

  func testOutsideRexUsesInBandQueryOnly() throws {
    let cli = try commandPaneCLI()
    let outsideRex = try resolver(runner: cli, environment: [:]).resolve(inBand: inBandDark, sourceBlock: nil)
    XCTAssertEqual(outsideRex, ResolvedTheme(colors: inBandDark, source: .terminalQuery))
    XCTAssertTrue(cli.calls.isEmpty)

    let empty = try resolver(runner: cli, environment: [:]).resolve(inBand: TerminalColorSet(), sourceBlock: nil)
    XCTAssertEqual(empty.palette, RenderPalette.fallback(dark: true))

    cli.palettes["block:source"] = Data("{\"content\":\"\\u001b]4;0;rgb:22/22/22\\u001b\\\\\"}".utf8)
    let incomplete = try resolver(runner: cli, prefs: [:]).resolve(inBand: inBandDark, sourceBlock: "block:source")
    XCTAssertEqual(incomplete.source, .terminalQuery)
  }

  func testCustomThemeFromPreferencesMatchesCaseInsensitively() throws {
    let ansi = [
      "#0A0B0C", "#C0392B", "#27AE60", "#F1C40F", "#2980B9", "#8E44AD", "#16A085", "#BDC3C7",
      "#7F8C8D", "#E74C3C", "#2ECC71", "#F39C12", "#3498DB", "#9B59B6", "#1ABC9C", "#ECF0F1",
    ]
    let custom: [[String: Any]] = [
      [
        "id": "0123456789abcdef0123456789abcdef-mine", "name": "Mine", "appearance": "dark",
        "source": ["background": "#0B0C0D", "foreground": "#E0E0E0", "selectionBackground": "#334455", "ansi": ansi],
      ]
    ]
    var prefs: [String: Any] = rexPrefs
    prefs["com.superlogical.rex Workspace.customThemes"] = try JSONSerialization.data(withJSONObject: custom)
    prefs["com.superlogical.rex Workspace.darkThemeID"] = "0123456789abcdef0123456789abcdef-mine"
    let cli = FakeRexCLI()
    cli.palettes["block:source"] = formatOutput(palette: ansi.map { hexValue(parseHexColor($0)!) })
    let resolved = try resolver(runner: cli, prefs: prefs).resolve(inBand: inBandDark, sourceBlock: "block:source")
    XCTAssertEqual(resolved.source, .rexTheme("0123456789abcdef0123456789abcdef-mine"))
    XCTAssertEqual(resolved.crossCheck, .confirmed(block: "block:source"))
    XCTAssertEqual(resolved.colors.background, RGB(hex: 0x0b0c0d))
    XCTAssertEqual(resolved.colors.selectionBackground, RGB(hex: 0x334455))
  }

  func testThemeParsingAcceptsSeveralShapes() throws {
    XCTAssertEqual(
      parseRexThemes(try fixture("rex-themes")).map(\.id), ["charcoal-atelier", "merino-dark", "merino-light"])
    let flat: [String: Any] = [
      "id": "flat", "background": "#000", "foreground": "#fff",
      "ansi": Dictionary(uniqueKeysWithValues: (0..<16).map { (String($0), "#112233") }),
    ]
    let fromPlist = parseRexThemes([flat])
    XCTAssertEqual(fromPlist.first?.background, RGB(hex: 0x000000))
    XCTAssertEqual(fromPlist.first?.ansi.count, 16)
    let wrapped = String(decoding: try JSONSerialization.data(withJSONObject: ["themes": [flat]]), as: UTF8.self)
    XCTAssertEqual(parseRexThemes(wrapped).map(\.id), ["flat"])
    XCTAssertTrue(
      parseRexThemes(["id": "short", "background": "#000", "foreground": "#fff", "ansi": ["#000"]]).isEmpty)
    XCTAssertTrue(parseRexThemes(nil).isEmpty)
    XCTAssertNil(parseHexColor("#12345"))
    XCTAssertEqual(parseHexColor("abc"), RGB(hex: 0xaabbcc))
  }

  private func lightTheme() throws -> RexTheme {
    try XCTUnwrap(parseRexThemes(try fixture("rex-themes")).first { $0.id == "merino-light" })
  }

  private func hexValue(_ color: RGB) -> UInt32 {
    UInt32(color.description.dropFirst(), radix: 16)!
  }
}
