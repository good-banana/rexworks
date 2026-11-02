import XCTest

@testable import MDViewerCore

final class TerminalColorsTests: XCTestCase {
  func testParsesReplyAndLuminance() {
    let rgb = parseColorReply("\u{1b}]11;rgb:1e1e/1e1e/2e2e\u{1b}\\")!
    XCTAssertTrue(isDark(rgb))
    XCTAssertFalse(isDark(parseColorReply("\u{1b}]11;rgb:ffff/ffff/ffff\u{07}")!))
    XCTAssertNil(parseColorReply("nope"))
  }

  func testParsesTwoDigitChannels() {
    let rgb = parseColorReply("\u{1b}]10;rgb:ff/00/80\u{07}")!
    XCTAssertEqual(rgb.r, 1.0, accuracy: 0.001)
    XCTAssertEqual(rgb.g, 0.0, accuracy: 0.001)
    XCTAssertEqual(rgb.b, 128.0 / 255.0, accuracy: 0.001)
  }

  func testRestoreSequenceUndoesEverything() {
    for mode in ["?2031l", "?2048l", "?1016l", "?1006l", "?1000l", "?25h", "?1049l"] {
      XCTAssertTrue(TerminalSequences.restore.contains(mode))
    }
    XCTAssertTrue(TerminalSequences.restore.contains(Kitty.deleteAll()))
  }

  func testRestoreDeletesImagesBeforeLeavingTheAlternateScreen() {
    XCTAssertEqual(
      TerminalSequences.restore,
      "\u{1b}[?2031l\u{1b}[?2048l\u{1b}[?1016l\u{1b}[?1006l\u{1b}[?1000l\u{1b}[?25h\u{1b}_Ga=d,d=A,q=2\u{1b}\\"
        + "\u{1b}[?1049l")
    XCTAssertEqual(TerminalSequences.queryCellSize, "\u{1b}[16t")
  }

  func testEnterSequenceEnablesModes() {
    for mode in ["?1049h", "?25l", "?1000h", "?1006h", "?1016h"] {
      XCTAssertTrue(TerminalSequences.enter.contains(mode))
    }
  }

  func testThemeFromTerminalColors() {
    let theme = Theme(foreground: (1, 1, 1), background: (0x1e / 255.0, 0x1e / 255.0, 0x2e / 255.0))
    XCTAssertEqual(theme, Theme(dark: true, background: "#1e1e2e", foreground: "#ffffff"))
  }

  func testThemeFallsBackToDarkWhenColorsAreMissing() {
    let theme = Theme(foreground: nil, background: nil)
    XCTAssertTrue(theme.dark)
    XCTAssertEqual(theme.background, "#1e1e1e")
  }

  func testThemeDerivesMissingForegroundFromBackground() {
    let theme = Theme(foreground: nil, background: (1, 1, 1))
    XCTAssertEqual(theme, Theme(dark: false, background: "#ffffff", foreground: "#1f2328"))
  }

  func testColorSchemeReportsAreOptInAndDisabledOnRestore() {
    XCTAssertEqual(TerminalSequences.enableColorSchemeReports, "\u{1b}[?2031h")
    XCTAssertFalse(TerminalSequences.enter.contains("?2031h"))
    XCTAssertTrue(TerminalSequences.restore.hasPrefix("\u{1b}[?2031l"))
  }
}
