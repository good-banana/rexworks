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
    XCTAssertEqual(p.feed([0x03]), [.key(.ctrl("c"))])
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

  func firstMouse(_ events: [InputEvent]) -> MouseEvent? {
    guard case .mouse(let mouse) = events.first else { return nil }
    return mouse
  }

  func testMouseButtonsAndModifiers() {
    var p = InputParser()
    let left = p.feed(Array("\u{1b}[<0;10;20M".utf8))
    XCTAssertEqual(left, [.mouse(.init(kind: .press, x: 9, y: 19))])
    XCTAssertEqual(firstMouse(left)?.isPrimaryClick, true)
    let middle = p.feed(Array("\u{1b}[<1;10;20M".utf8))
    XCTAssertEqual(middle, [.mouse(.init(kind: .press, x: 9, y: 19, button: 1))])
    let right = p.feed(Array("\u{1b}[<2;10;20M".utf8))
    XCTAssertEqual(right, [.mouse(.init(kind: .press, x: 9, y: 19, button: 2))])
    XCTAssertEqual(firstMouse(right)?.isPrimaryClick, false)
    let ctrlLeft = p.feed(Array("\u{1b}[<16;10;20M".utf8))
    XCTAssertEqual(ctrlLeft, [.mouse(.init(kind: .press, x: 9, y: 19, modifiers: .control))])
    XCTAssertEqual(firstMouse(ctrlLeft)?.isPrimaryClick, false)
    let shiftAltLeft = p.feed(Array("\u{1b}[<12;10;20M".utf8))
    XCTAssertEqual(shiftAltLeft, [.mouse(.init(kind: .press, x: 9, y: 19, modifiers: [.shift, .alt]))])
    let leftRelease = p.feed(Array("\u{1b}[<0;10;20m".utf8))
    XCTAssertEqual(firstMouse(leftRelease)?.isPrimaryClick, false)
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

  func testColorSchemeNotifications() {
    var p = InputParser()
    XCTAssertEqual(p.feed(Array("\u{1b}[?997;1n".utf8)), [.colorScheme(.dark)])
    XCTAssertEqual(p.feed(Array("\u{1b}[?997;2n".utf8)), [.colorScheme(.light)])
    XCTAssertEqual(p.feed(Array("\u{1b}[?997;3n\u{1b}[?996n\u{1b}[997;1n".utf8)), [])
    XCTAssertEqual(p.feed(Array("\u{1b}[?99".utf8)), [])
    XCTAssertEqual(p.feed(Array("7;2nj".utf8)), [.colorScheme(.light), .key(.char("j"))])
  }

  func testColorSchemeNotificationsBetweenOtherInput() {
    var p = InputParser()
    let stream = "k\u{1b}[A\u{1b}[?997;1n\u{1b}[<0;5;6M\u{1b}[5~\u{1b}[?997;2nq"
    XCTAssertEqual(
      p.feed(Array(stream.utf8)),
      [
        .key(.char("k")), .key(.up), .colorScheme(.dark), .mouse(.init(kind: .press, x: 4, y: 5)),
        .key(.pageUp), .colorScheme(.light), .key(.char("q")),
      ])
  }

  func testLateColorRepliesAreNotKeystrokes() {
    var p = InputParser()
    let reply = "\u{1b}]4;1;rgb:cccc/6666/6666\u{1b}\\\u{1b}]11;rgb:1e/1e/1e\u{07}g"
    XCTAssertEqual(p.feed(Array(reply.utf8)), [.key(.char("g"))])
    XCTAssertEqual(p.feed(Array("\u{1b}]10;rgb:ff".utf8)), [])
    XCTAssertEqual(p.feed(Array("/ff/ff\u{1b}".utf8)), [])
    XCTAssertEqual(p.feed(Array("\\r".utf8)), [.key(.char("r"))])
    XCTAssertEqual(p.feed(Array("\u{1b}]10;rgb:ff\u{1b}[B".utf8)), [.key(.down)])
  }

  func testUnterminatedOSCIsEventuallyDropped() {
    var p = InputParser()
    XCTAssertEqual(p.feed(Array("\u{1b}]52;".utf8) + Array(repeating: 0x41, count: 5000)), [])
    XCTAssertEqual(p.feed(Array("j".utf8)), [.key(.char("j"))])
  }

  func testThemeResolveTriggers() {
    XCTAssertTrue(InputEvent.colorScheme(.dark).requestsThemeResolve)
    XCTAssertTrue(InputEvent.colorScheme(.light).requestsThemeResolve)
    XCTAssertTrue(InputEvent.key(.char("r")).requestsThemeResolve)
    XCTAssertFalse(InputEvent.key(.char("R")).requestsThemeResolve)
    XCTAssertFalse(InputEvent.mouse(.init(kind: .press, x: 0, y: 0)).requestsThemeResolve)
  }

  func testAltBracketDoesNotFreezeInput() {
    var p = InputParser()
    XCTAssertEqual(p.feed([0x1b, 0x5d]), [])
    XCTAssertEqual(p.feed(Array("q".utf8)), [.key(.escape), .key(.char("]")), .key(.char("q"))])
    XCTAssertEqual(p.feed(Array("\u{1b}]1".utf8)), [])
    XCTAssertEqual(
      p.feed(Array("0j".utf8)), [.key(.escape), .key(.char("]")), .key(.char("1")), .key(.char("0")), .key(.char("j"))])
    XCTAssertEqual(p.feed(Array("\u{1b};k".utf8)), [.key(.escape), .key(.char(";")), .key(.char("k"))])
    XCTAssertEqual(
      p.feed(Array("\u{1b}];k".utf8)), [.key(.escape), .key(.char("]")), .key(.char(";")), .key(.char("k"))])
  }

  func testDeviceAttributesReplies() {
    var p = InputParser()
    XCTAssertEqual(p.feed(Array("\u{1b}[?62;22c".utf8)), [.deviceAttributes])
    XCTAssertEqual(p.feed(Array("\u{1b}[?997;1n\u{1b}[?6".utf8)), [.colorScheme(.dark)])
    XCTAssertEqual(p.feed(Array("2cj".utf8)), [.deviceAttributes, .key(.char("j"))])
    XCTAssertEqual(p.feed(Array("\u{1b}[c\u{1b}[>1;10;0c".utf8)), [])
    XCTAssertFalse(InputEvent.deviceAttributes.requestsThemeResolve)
  }

  func testEditKeysParse() {
    var p = InputParser()
    XCTAssertEqual(p.feed([0x45]), [.key(.char("E"))])
    XCTAssertEqual(p.feed([0x05]), [.key(.ctrl("e"))])
    XCTAssertEqual(p.feed(Array("\u{1b}[101;5u".utf8)), [.key(.ctrl("e"))])
    XCTAssertEqual(p.feed(Array("\u{1b}[101;3u".utf8)), [], "Alt-E is dropped")
    XCTAssertEqual(p.feed(Array("\u{1b}[?62;22c".utf8)), [.deviceAttributes])
    XCTAssertEqual(p.feed(Array(",".utf8)), [.key(.char(","))])
  }

  func testInBandSizeReports() {
    var p = InputParser()
    XCTAssertEqual(
      p.feed(Array("\u{1b}[48;61;70;2013;980tj".utf8)),
      [.paneSize(PaneSize(columns: 70, rows: 61, pixelWidth: 980, pixelHeight: 2013)), .key(.char("j"))])
    XCTAssertEqual(p.feed(Array("\u{1b}[48;61;70t".utf8)), [])
    XCTAssertEqual(p.feed(Array("\u{1b}[?2048;2$y".utf8)), [.modeReport(ModeReport(mode: 2048, state: 2))])
    XCTAssertFalse(ModeReport(mode: 2048, state: 0).isRecognized)
  }

  func testGraphicsResponses() {
    var p = InputParser()
    XCTAssertEqual(
      p.feed(Array("\u{1b}_Gi=2147483648;OK\u{1b}\\k".utf8)),
      [.graphics(GraphicsResponse(id: 2_147_483_648, message: "OK")), .key(.char("k"))])
    XCTAssertEqual(p.feed(Array("\u{1b}_Gi=5,r=1;ENOENT: image".utf8)), [])
    XCTAssertEqual(
      p.feed(Array(" not found\u{1b}".utf8)), [])
    XCTAssertEqual(
      p.feed(Array("\\".utf8)), [.graphics(GraphicsResponse(id: 5, message: "ENOENT: image not found"))])
  }

  func testAltUnderscoreIsNotAGraphicsResponse() {
    var p = InputParser()
    XCTAssertEqual(p.feed(Array("\u{1b}_x".utf8)), [.key(.escape), .key(.char("_")), .key(.char("x"))])
    XCTAssertEqual(
      p.feed(Array("\u{1b}_G j".utf8)),
      [.key(.escape), .key(.char("_")), .key(.char("G")), .key(.char(" ")), .key(.char("j"))])
  }

  func testPaneSizeHasPixels() {
    XCTAssertTrue(PaneSize(columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 480).hasPixels)
    XCTAssertFalse(PaneSize(columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0).hasPixels)
  }

  func testCellSizeReports() {
    var p = InputParser()
    XCTAssertEqual(p.feed(Array("\u{1b}[6;33;14t".utf8)), [.cellSize(width: 14, height: 33)])
    XCTAssertEqual(p.feed(Array("\u{1b}[6;0;14t".utf8)), [])
  }

  func testLoneTrailingEscapeIsHeldUntilTheTimeout() {
    var p = InputParser()
    XCTAssertEqual(p.feed(Array("j\u{1b}".utf8), at: 1_000), [.key(.char("j"))])
    XCTAssertEqual(p.escapeDeadline, 1_000 + InputParser.escapeTimeout)
    XCTAssertEqual(p.flushEscape(at: 1_000 + InputParser.escapeTimeout - 1), [])
    XCTAssertEqual(p.flushEscape(at: 1_000 + InputParser.escapeTimeout), [.key(.escape)])
    XCTAssertNil(p.escapeDeadline)
    XCTAssertEqual(p.flushEscape(at: 10_000_000_000), [])
  }

  func testHeldEscapeJoinsALaterSequence() {
    var p = InputParser()
    XCTAssertEqual(p.feed([0x1b], at: 0), [])
    XCTAssertEqual(p.feed(Array("[B".utf8), at: 1), [.key(.down)])
    XCTAssertNil(p.escapeDeadline)
    XCTAssertEqual(p.flushEscape(at: 1_000_000_000), [])
    XCTAssertEqual(p.feed([0x1b], at: 2), [])
    XCTAssertEqual(p.feed(Array("x".utf8), at: 3), [.key(.escape), .key(.char("x"))])
  }

  func testLegacyFeedStillReportsALoneEscapeAtOnce() {
    var p = InputParser()
    XCTAssertEqual(p.feed([0x1b]), [.key(.escape)])
  }
}
