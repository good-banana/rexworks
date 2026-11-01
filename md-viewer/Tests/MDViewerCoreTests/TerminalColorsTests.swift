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
    for mode in ["?1016l", "?1006l", "?1000l", "?25h", "?1049l"] {
      XCTAssertTrue(TerminalSequences.restore.contains(mode))
    }
    XCTAssertTrue(TerminalSequences.restore.contains(Kitty.deleteAll()))
  }

  func testEnterSequenceEnablesModes() {
    for mode in ["?1049h", "?25l", "?1000h", "?1006h", "?1016h"] {
      XCTAssertTrue(TerminalSequences.enter.contains(mode))
    }
  }
}
