import Foundation
import XCTest

@testable import MDViewerCore

final class InteractionInputTests: XCTestCase {
  func events(_ text: String) -> [InputEvent] {
    var parser = InputParser()
    return parser.feed(Array(text.utf8))
  }

  func testHorizontalArrows() {
    XCTAssertEqual(events("\u{1b}[D\u{1b}[C\u{1b}OD\u{1b}OC"), [.key(.left), .key(.right), .key(.left), .key(.right)])
    XCTAssertEqual(events("\u{1b}[1;2D"), [.key(.left)])
  }

  func testKittyKeyboardProtocolKeys() {
    XCTAssertEqual(events("\u{1b}[99;9u"), [.key(.command("c"))], "Cmd-C as Ghostty and Rex send it")
    XCTAssertEqual(events("\u{1b}[99;5u"), [.key(.ctrl("c"))])
    XCTAssertEqual(events("\u{1b}[127;2u"), [.key(.shiftBackspace)])
    XCTAssertEqual(events("\u{1b}[127u"), [.key(.backspace)])
    XCTAssertEqual(events("\u{1b}[27u"), [.key(.escape)])
    XCTAssertEqual(events("\u{1b}[13u"), [.key(.enter)])
    XCTAssertEqual(events("\u{1b}[9;2u"), [.key(.backTab)])
    XCTAssertEqual(events("\u{1b}[108;2u"), [.key(.char("L"))])
    XCTAssertEqual(events("\u{1b}[99:67;9u"), [.key(.command("c"))], "alternate key fields are ignored")
    XCTAssertEqual(events("\u{1b}[57441u"), [], "other private-use functional keys (left Shift) are dropped")
    XCTAssertEqual(events("\u{1b}[?1u"), [], "a flags reply is not a key")
    XCTAssertEqual(events("\u{1b}[113;5u"), [.key(.ctrl("q"))])
    XCTAssertEqual(
      events("\u{1b}[1;5A\u{1b}[1;2B\u{1b}[1;5C\u{1b}[1;3D"), [.key(.up), .key(.down), .key(.right), .key(.left)])
    XCTAssertEqual(events("\u{1b}[5;5~"), [.key(.pageUp)])
    XCTAssertEqual(events("\u{1b}[106;3u"), [], "Alt plus a key is not the bare key")
    XCTAssertEqual(events("\u{1b}[223;2u"), [.key(.char("\u{df}"))], "multi-character uppercase keeps the key")
  }

  func testKeypadKeysUnderTheKittyProtocol() {
    XCTAssertEqual(events("\u{1b}[57414u"), [.key(.enter)], "keypad Enter, also fn-Return on Mac laptops")
    XCTAssertEqual(events("\u{1b}[57414;1u"), [.key(.enter)])
    XCTAssertEqual(events("\u{1b}OM"), [.key(.enter)], "keypad Enter in application keypad mode")
    XCTAssertEqual(
      events("\u{1b}[57399u\u{1b}[57408u\u{1b}[57413u\u{1b}[57412u\u{1b}[57415u\u{1b}[57410u"),
      [.key(.char("0")), .key(.char("9")), .key(.char("+")), .key(.char("-")), .key(.char("=")), .key(.char("/"))])
    XCTAssertEqual(
      events("\u{1b}[57419u\u{1b}[57420u\u{1b}[57421u\u{1b}[57422u\u{1b}[57423u\u{1b}[57424u"),
      [.key(.up), .key(.down), .key(.pageUp), .key(.pageDown), .key(.home), .key(.end)])
  }

  func testModifyOtherKeys() {
    XCTAssertEqual(events("\u{1b}[27;2;127~"), [.key(.shiftBackspace)])
    XCTAssertEqual(events("\u{1b}[27;2;9~"), [.key(.backTab)])
    XCTAssertEqual(events("\u{1b}[27;9;99~"), [.key(.command("c"))])
  }

  func testMotionAndHorizontalWheel() {
    XCTAssertEqual(events("\u{1b}[<32;10;20M"), [.mouse(.init(kind: .motion, x: 9, y: 19, button: 0))])
    XCTAssertEqual(events("\u{1b}[<35;10;20M"), [.mouse(.init(kind: .motion, x: 9, y: 19, button: 3))])
    XCTAssertEqual(
      events("\u{1b}[<36;10;20M"), [.mouse(.init(kind: .motion, x: 9, y: 19, button: 0, modifiers: .shift))])
    XCTAssertEqual(events("\u{1b}[<66;10;20M"), [.mouse(.init(kind: .wheelLeft, x: 9, y: 19))])
    XCTAssertEqual(events("\u{1b}[<67;10;20M"), [.mouse(.init(kind: .wheelRight, x: 9, y: 19))])
    XCTAssertEqual(
      events("\u{1b}[<68;10;20M"), [.mouse(.init(kind: .wheelUp, x: 9, y: 19, modifiers: .shift))],
      "Shift plus wheel keeps its modifier")
    XCTAssertEqual(events("\u{1b}[<3;10;20m"), [.mouse(.init(kind: .release, x: 9, y: 19, button: 3))])
  }

  func testInteractionSequences() {
    XCTAssertEqual(TerminalSequences.enableMouseMotion, "\u{1b}[?1003h")
    XCTAssertEqual(TerminalSequences.enableKeyboardDisambiguation, "\u{1b}[>1u")
    XCTAssertEqual(TerminalSequences.enableShiftCapture, "\u{1b}[>1s")
    let restore = TerminalSequences.restore
    let shiftReset = restore.range(of: "\u{1b}[>0s")!
    XCTAssertLessThan(shiftReset.lowerBound, restore.range(of: "\u{1b}[?1049l")!.lowerBound)
    XCTAssertTrue(TerminalSequences.restore.hasPrefix("\u{1b}[?2031l\u{1b}[<u\u{1b}[>0s\u{1b}[?1003l"))
  }
}

final class HistoryForwardTests: XCTestCase {
  let a = History.Entry(file: URL(fileURLWithPath: "/a.md"), offset: 10)
  let b = History.Entry(file: URL(fileURLWithPath: "/b.md"), offset: 20)
  let c = History.Entry(file: URL(fileURLWithPath: "/c.md"), offset: 30)

  func testBackAndForward() {
    var history = History()
    history.push(a)
    history.push(b)
    XCTAssertFalse(history.canGoForward)
    XCTAssertEqual(history.back(from: c), b)
    XCTAssertTrue(history.canGoForward)
    XCTAssertEqual(history.back(from: b), a)
    XCTAssertNil(history.back(from: a))
    XCTAssertEqual(history.forward(from: a), b)
    XCTAssertEqual(history.forward(from: b), c)
    XCTAssertNil(history.forward(from: c))
    XCTAssertEqual(history.back(from: c), b)
  }

  func testPushClearsForward() {
    var history = History()
    history.push(a)
    _ = history.back(from: b)
    XCTAssertTrue(history.canGoForward)
    history.push(c)
    XCTAssertFalse(history.canGoForward)
  }
}

struct FakePreferences: PreferenceReading {
  var values: [String: Any]

  func value(forKey key: String, domain: String) -> Any? {
    domain == "com.superlogical.rex" ? values[key] : nil
  }
}

final class RexPreferencesTests: XCTestCase {
  func testCopyOnSelectFollowsRex() {
    XCTAssertTrue(RexPreferences(reader: FakePreferences(values: [RexPreferences.copyOnSelectKey: true])).copyOnSelect)
    XCTAssertTrue(
      RexPreferences(reader: FakePreferences(values: [RexPreferences.copyOnSelectKey: NSNumber(value: 1)])).copyOnSelect
    )
    XCTAssertFalse(
      RexPreferences(reader: FakePreferences(values: [RexPreferences.copyOnSelectKey: NSNumber(value: 0)])).copyOnSelect
    )
    XCTAssertFalse(RexPreferences(reader: FakePreferences(values: [:])).copyOnSelect)
  }
}
