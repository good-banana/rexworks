import XCTest

@testable import MDViewerCore

final class RenderPaletteTests: XCTestCase {
  private let tomorrowNight = TerminalColorSet(
    foreground: RGB(hex: 0xc5c8c6), background: RGB(hex: 0x1d1f21),
    palette: [
      0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
      0x969896, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
    ].map { RGB(hex: $0) })

  private let githubLight = TerminalColorSet(
    foreground: RGB(hex: 0x1f2328), background: RGB(hex: 0xffffff),
    palette: [
      0x24292f, 0xcf222e, 0x116329, 0x4d2d00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
      0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f,
    ].map { RGB(hex: $0) })

  func testDarkDerivationPicksExpectedHues() {
    let palette = RenderPalette(colors: tomorrowNight)
    let ansi = tomorrowNight.palette.map { $0! }
    XCTAssertTrue(palette.dark)
    XCTAssertEqual(palette.pageBackground, RGB(hex: 0x1d1f21))
    XCTAssertEqual(palette.text, RGB(hex: 0xc5c8c6))
    XCTAssertEqual(palette.link, ansi[12])
    XCTAssertEqual(palette.linkVisited, palette.link)
    XCTAssertEqual(palette.focusOutline, ansi[12])
    XCTAssertEqual(palette.alerts.note, ansi[12])
    XCTAssertEqual(palette.alerts.tip, ansi[10])
    XCTAssertEqual(palette.alerts.important, ansi[13])
    XCTAssertEqual(palette.alerts.warning, ansi[3])
    assertSameHue(palette.alerts.caution, ansi[1])
    XCTAssertEqual(palette.syntax.keyword, ansi[13])
    XCTAssertEqual(palette.syntax.string, ansi[10])
    XCTAssertEqual(palette.syntax.function, ansi[12])
    XCTAssertEqual(palette.syntax.type, ansi[3])
    XCTAssertEqual(palette.syntax.attribute, ansi[3])
    XCTAssertEqual(palette.syntax.comment, ansi[8])
    XCTAssertEqual(palette.syntax.number, ansi[6])
    assertSameHue(palette.syntax.variable, ansi[1])
    assertSameHue(palette.syntax.metaTag, ansi[1])
    XCTAssertEqual(palette.syntax.operatorSymbol, palette.text)
  }

  func testLightDerivationPicksExpectedHues() {
    let palette = RenderPalette(colors: githubLight)
    let ansi = githubLight.palette.map { $0! }
    XCTAssertFalse(palette.dark)
    XCTAssertEqual(palette.link, ansi[4])
    XCTAssertEqual(palette.alerts.note, ansi[4])
    XCTAssertEqual(palette.alerts.tip, ansi[2])
    XCTAssertEqual(palette.alerts.important, ansi[5])
    XCTAssertEqual(palette.alerts.warning, ansi[3])
    XCTAssertEqual(palette.alerts.caution, ansi[9])
    assertSameHue(palette.syntax.string, ansi[2])
    assertSameHue(palette.syntax.keyword, ansi[5])
    assertSameHue(palette.syntax.function, ansi[4])
  }

  func testBrightSlotsWithDifferentHueAreNotUsed() {
    let solarizedDark = TerminalColorSet(
      foreground: RGB(hex: 0x839496), background: RGB(hex: 0x002b36),
      palette: [
        0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
        0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
      ].map { RGB(hex: $0) })
    let palette = RenderPalette(colors: solarizedDark)
    assertSameHue(palette.alerts.tip, RGB(hex: 0x859900))
    assertSameHue(palette.alerts.warning, RGB(hex: 0xb58900))
    assertSameHue(palette.link, RGB(hex: 0x268bd2))
    assertSameHue(palette.alerts.important, RGB(hex: 0xd33682))
    assertSameHue(palette.syntax.number, RGB(hex: 0x2aa198))
    XCTAssertEqual(RenderPalette.hueDistance(350, 10), 20)
  }

  func testTintsMixTowardForeground() {
    let palette = RenderPalette(colors: tomorrowNight)
    let bg = RGB(hex: 0x1d1f21)
    for tint in [
      palette.codeBlockBackground, palette.inlineCodeBackground, palette.tableHeaderFill, palette.tableStripe,
      palette.statusBarBackground, palette.frontmatterBackground, palette.border,
    ] {
      XCTAssertGreaterThan(tint.relativeLuminance, bg.relativeLuminance)
      XCTAssertLessThan(tint.contrast(with: bg), 2)
    }
    XCTAssertGreaterThan(palette.inlineCodeBackground.contrast(with: bg), palette.tableStripe.contrast(with: bg))
    XCTAssertLessThan(palette.mutedText.contrast(with: bg), palette.text.contrast(with: bg))
    XCTAssertNotEqual(palette.findHighlight, palette.currentMatchHighlight)
    XCTAssertNotEqual(palette.selectionFill, palette.pageBackground)
  }

  func testEveryTokenMeetsItsRatioForLowContrastPalette() {
    let murky = TerminalColorSet(
      foreground: RGB(hex: 0x3a3a3a), background: RGB(hex: 0x303030),
      palette: (0..<16).map { _ in RGB(hex: 0x353535) })
    let murkyLight = TerminalColorSet(
      foreground: RGB(hex: 0xdddddd), background: RGB(hex: 0xeeeeee),
      palette: [0xf0e0e0, 0xffeeee, 0xeeffee, 0xffffdd, 0xddeeff, 0xffddff, 0xddffff, 0xf8f8f8]
        .map { RGB(hex: $0) }
        + [0xe0e0e0, 0xffe0e0, 0xe0ffe0, 0xffffe0, 0xe0e0ff, 0xffe0ff, 0xe0ffff, 0xffffff]
        .map { RGB(hex: $0) })
    let midGray = TerminalColorSet(
      foreground: RGB(hex: 0x777777), background: RGB(hex: 0x767676),
      palette: (0..<16).map { _ in RGB(hex: 0x787878) })
    for colors in [murky, murkyLight, midGray, tomorrowNight, githubLight, TerminalColorSet()] {
      assertMeetsRequirements(RenderPalette(colors: colors))
    }
  }

  func testContrastRequirementsCoverTextAndUITokens() {
    let names = Set(RenderPalette.contrastRequirements.map(\.name))
    for name in [
      "text", "mutedText", "headingText", "link", "linkVisited", "inlineCodeText", "statusBarText", "statusMutedText",
      "statusHintText", "alerts.note",
      "alerts.caution", "syntax.keyword", "syntax.comment", "syntax.punctuation",
    ] {
      let requirement = RenderPalette.contrastRequirements.first { $0.name == name }
      XCTAssertEqual(requirement?.minimum, RenderPalette.textContrast, name)
    }
    for name in ["focusOutline", "blockquoteBar", "progressFill", "frontmatterBar"] {
      let requirement = RenderPalette.contrastRequirements.first { $0.name == name }
      XCTAssertEqual(requirement?.minimum, RenderPalette.uiContrast, name)
    }
    XCTAssertEqual(names.count, RenderPalette.contrastRequirements.count)
  }

  func testEnsureContrastKeepsHueAndChangesOnlyWhenNeeded() {
    let bg = RGB(hex: 0x202020)
    let goodBlue = RGB(hex: 0x7aa6da)
    XCTAssertEqual(ensureContrast(goodBlue, against: bg, minimum: 4.5), goodBlue)
    let darkBlue = RGB(hex: 0x102050)
    let adjusted = ensureContrast(darkBlue, against: bg, minimum: 4.5)
    XCTAssertGreaterThanOrEqual(adjusted.contrast(with: bg), 4.5)
    XCTAssertGreaterThan(adjusted.b, adjusted.r)
    XCTAssertEqual(adjusted.hsl.hue, darkBlue.hsl.hue, accuracy: 1)
    let onWhite = ensureContrast(RGB(hex: 0xfff0a0), against: RGB(hex: 0xffffff), minimum: 4.5)
    XCTAssertGreaterThanOrEqual(onWhite.contrast(with: RGB(hex: 0xffffff)), 4.5)
    XCTAssertLessThan(onWhite.relativeLuminance, 0.5)
  }

  func testFallbacksWhenQueriesFail() {
    let unknown = RenderPalette(colors: TerminalColorSet())
    XCTAssertEqual(unknown, RenderPalette.fallback(dark: true))
    XCTAssertTrue(unknown.dark)
    XCTAssertEqual(unknown.pageBackground, RGB(hex: 0x1e1e1e))
    XCTAssertEqual(unknown.text, RGB(hex: 0xd4d4d4))

    let light = RenderPalette.fallback(dark: false)
    XCTAssertFalse(light.dark)
    XCTAssertEqual(light.pageBackground, RGB(hex: 0xffffff))
    XCTAssertEqual(light.link, RGB(hex: 0x0969da))
    assertMeetsRequirements(light)

    let lightFromForeground = RenderPalette(colors: TerminalColorSet(foreground: RGB(hex: 0x111111)))
    XCTAssertFalse(lightFromForeground.dark)
    XCTAssertEqual(lightFromForeground.pageBackground, RGB(hex: 0xffffff))
    XCTAssertEqual(lightFromForeground.text, RGB(hex: 0x111111))

    let lightFromScheme = RenderPalette(colors: TerminalColorSet(colorScheme: .light))
    XCTAssertEqual(lightFromScheme, RenderPalette.fallback(dark: false))
    let backgroundWins = RenderPalette(colors: TerminalColorSet(background: RGB(hex: 0x101010), colorScheme: .light))
    XCTAssertTrue(backgroundWins.dark)

    var partial = tomorrowNight
    partial.palette[4] = nil
    partial.palette[12] = nil
    let fallbackBlue = RenderPalette(colors: partial)
    XCTAssertEqual(fallbackBlue.link, RGB(hex: 0x7aa6da))
    assertSameHue(fallbackBlue.alerts.caution, RGB(hex: 0xcc6666))
  }

  func testRGBHelpers() {
    XCTAssertEqual(RGB(hex: 0x000000).contrast(with: RGB(hex: 0xffffff)), 21, accuracy: 0.001)
    XCTAssertEqual(RGB(hex: 0x1e1e2e).description, "#1e1e2e")
    XCTAssertEqual(RGB(hex: 0x000000).mixed(with: RGB(hex: 0xffffff), 0.5), RGB(0.5, 0.5, 0.5))
    for hex: UInt32 in [0xcc6666, 0x7aa6da, 0xb5bd68, 0x8250df, 0x808080, 0xffffff] {
      let color = RGB(hex: hex)
      let hsl = color.hsl
      let round = RGB(hue: hsl.hue, saturation: hsl.saturation, lightness: hsl.lightness)
      XCTAssertEqual(round.r, color.r, accuracy: 1e-9)
      XCTAssertEqual(round.g, color.g, accuracy: 1e-9)
      XCTAssertEqual(round.b, color.b, accuracy: 1e-9)
    }
  }

  private func assertSameHue(_ token: RGB, _ source: RGB, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(token.hsl.hue, source.hsl.hue, accuracy: 1, file: file, line: line)
    XCTAssertEqual(token.hsl.saturation, source.hsl.saturation, accuracy: 0.02, file: file, line: line)
  }

  private func assertMeetsRequirements(
    _ palette: RenderPalette, file: StaticString = #filePath, line: UInt = #line
  ) {
    for requirement in RenderPalette.contrastRequirements {
      let ratio = palette[keyPath: requirement.token].contrast(with: palette[keyPath: requirement.backdrop])
      XCTAssertGreaterThanOrEqual(ratio, requirement.minimum, requirement.name, file: file, line: line)
    }
  }
}
