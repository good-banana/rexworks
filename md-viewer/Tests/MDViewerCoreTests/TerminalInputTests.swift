import XCTest

@testable import MDViewerCore

final class TerminalInputTests: XCTestCase {
  func testKeysAndSplitSequences() {
    var p = InputParser()
    XCTAssertEqual(p.feed(Array("j".utf8)), [.key(.char("j"))])
    XCTAssertEqual(p.feed([0x1b, 0x5b]), [])
    XCTAssertEqual(p.feed([0x42]), [.key(.down)])
    XCTAssertEqual(p.feed(Array("\u{1b}[5~".utf8)), [.key(.pageUp)])
    XCTAssertEqual(p.feed([0x11]), [.key(.ctrl("q"))])
  }

  func testSGRPixelMouse() {
    var p = InputParser()
    XCTAssertEqual(
      p.feed(Array("\u{1b}[<0;412;87M".utf8)), [.mouse(.init(kind: .press, x: 411, y: 86))])
    XCTAssertEqual(
      p.feed(Array("\u{1b}[<65;10;10M".utf8)), [.mouse(.init(kind: .wheelDown, x: 9, y: 9))])
    XCTAssertEqual(
      p.feed(Array("\u{1b}[<64;10;10M".utf8)), [.mouse(.init(kind: .wheelUp, x: 9, y: 9))])
    XCTAssertEqual(
      p.feed(Array("\u{1b}[<0;5;6m".utf8)), [.mouse(.init(kind: .release, x: 4, y: 5))])
  }

  func testNamedKeys() {
    var p = InputParser()
    XCTAssertEqual(p.feed(Array("\u{1b}[A".utf8)), [.key(.up)])
    XCTAssertEqual(p.feed(Array("\u{1b}[6~".utf8)), [.key(.pageDown)])
    XCTAssertEqual(p.feed(Array("\u{1b}[H".utf8)), [.key(.home)])
    XCTAssertEqual(p.feed(Array("\u{1b}[F".utf8)), [.key(.end)])
    XCTAssertEqual(p.feed(Array("\u{1b}[Z".utf8)), [.key(.backTab)])
    XCTAssertEqual(p.feed([0x0d]), [.key(.enter)])
    XCTAssertEqual(p.feed([0x09]), [.key(.tab)])
    XCTAssertEqual(p.feed([0x7f]), [.key(.backspace)])
    XCTAssertEqual(p.feed([0x1b]), [.key(.escape)])
  }

  func testSplitMouseAndMultipleEvents() {
    var p = InputParser()
    XCTAssertEqual(p.feed(Array("\u{1b}[<0;4".utf8)), [])
    XCTAssertEqual(p.feed(Array("1;8M".utf8)), [.mouse(.init(kind: .press, x: 40, y: 7))])
    XCTAssertEqual(p.feed(Array("jk".utf8)), [.key(.char("j")), .key(.char("k"))])
  }

  func testMultibyteCharacter() {
    var p = InputParser()
    XCTAssertEqual(p.feed([0xc3]), [])
    XCTAssertEqual(p.feed([0xa9]), [.key(.char("é"))])
  }
}
