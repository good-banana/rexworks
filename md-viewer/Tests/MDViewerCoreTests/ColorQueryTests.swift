import XCTest

@testable import MDViewerCore

final class ColorQueryTests: XCTestCase {
  private let st = "\u{1b}\\"
  private let bel = "\u{07}"

  func testRequestBatchesDynamicAndPaletteQueries() {
    let request = TerminalColorQuery.request(includePalette: true)
    XCTAssertTrue(request.hasPrefix("\u{1b}]10;?\(st)\u{1b}]11;?\(st)"))
    for index in 0..<16 {
      XCTAssertTrue(request.contains("\u{1b}]4;\(index);?\(st)"))
    }
    XCTAssertFalse(request.contains("]4;16;"))
    XCTAssertTrue(request.hasSuffix("\u{1b}]4;15;?\(st)\u{1b}[?996n\u{1b}[c"))
    XCTAssertEqual(
      TerminalColorQuery.request(includePalette: false), "\u{1b}]10;?\(st)\u{1b}]11;?\(st)\u{1b}[?996n\u{1b}[c")
  }

  func testParsesEveryReplyForm() {
    let fourDigit = parseOSCColorReply("4;12;rgb:7a7a/a6a6/dada")
    XCTAssertEqual(fourDigit?.target, .palette(12))
    XCTAssertEqual(fourDigit?.color, RGB(hex: 0x7aa6da))
    let twoDigit = parseOSCColorReply("4;3;rgb:f0/c6/74")
    XCTAssertEqual(twoDigit?.target, .palette(3))
    XCTAssertEqual(twoDigit?.color, RGB(hex: 0xf0c674))
    XCTAssertEqual(parseOSCColorReply("10;rgb:d4d4/d4d4/d4d4")?.target, .foreground)
    XCTAssertEqual(parseOSCColorReply("11;rgb:1e/1e/1e")?.color, RGB(hex: 0x1e1e1e))
    XCTAssertNil(parseOSCColorReply("4;3;?"))
    XCTAssertNil(parseOSCColorReply("12;rgb:ff/ff/ff"))
    XCTAssertNil(parseOSCColorReply("4;x;rgb:ff/ff/ff"))
    XCTAssertNil(parseOSCColorReply("4;300;rgb:ff/ff/ff"))
    XCTAssertNil(parseOSCColorReply("11;rgb:ff/ff"))
  }

  func testReaderAcceptsBothTerminators() {
    var reader = TerminalColorReplyReader(expectsPalette: false)
    reader.feed(Array("\u{1b}]10;rgb:ffff/ffff/ffff\(st)\u{1b}]11;rgb:00/00/00\(bel)".utf8))
    XCTAssertFalse(reader.isComplete)
    reader.feed(Array("\u{1b}[?997;2n".utf8))
    XCTAssertTrue(reader.isComplete)
    XCTAssertEqual(reader.colors.colorScheme, .light)
    XCTAssertEqual(reader.colors.foreground, RGB(hex: 0xffffff))
    XCTAssertEqual(reader.colors.background, RGB(hex: 0x000000))
  }

  func testReaderCompletesOnlyWithAllSixteenPaletteEntries() {
    var reader = TerminalColorReplyReader(expectsPalette: true)
    reader.feed(Array(fullReply(skipping: 15).utf8))
    XCTAssertFalse(reader.isComplete)
    reader.feed(Array("\u{1b}]4;15;rgb:eaea/eaea/eaea\(st)".utf8))
    XCTAssertTrue(reader.isComplete)
    XCTAssertEqual(reader.colors.palette[15], RGB(hex: 0xeaeaea))
    XCTAssertEqual(reader.colors.palette[4], RGB(hex: 0x040404))
  }

  func testReaderHandlesRepliesSplitAtEveryByte() {
    var reader = TerminalColorReplyReader(expectsPalette: true)
    for byte in Array(fullReply().utf8) { reader.feed([byte]) }
    XCTAssertTrue(reader.isComplete)
    XCTAssertEqual(reader.colors.palette[9], RGB(hex: 0x090909))
  }

  func testReaderDropsInterleavedInputAndOutOfOrderReplies() {
    var reader = TerminalColorReplyReader(expectsPalette: true)
    let stream =
      "j\u{1b}[<0;3;4M\u{1b}]4;7;rgb:07/07/07\(bel)\u{1b}[A"
      + "\u{1b}]11;rgb:1111/2222/3333\(st)q\u{1b}]4;1"
    reader.feed(Array(stream.utf8))
    reader.feed(Array(";rgb:01/01/01\(st)\u{1b}[?997;1n".utf8))
    XCTAssertEqual(reader.colors.palette[7], RGB(hex: 0x070707))
    XCTAssertEqual(reader.colors.palette[1], RGB(hex: 0x010101))
    XCTAssertEqual(reader.colors.background, RGB(0x1111 / 65535.0, 0x2222 / 65535.0, 0x3333 / 65535.0))
    XCTAssertNil(reader.colors.foreground)
    reader.feed(Array(fullReply().utf8))
    XCTAssertTrue(reader.isComplete)
    XCTAssertEqual(reader.colors.background, RGB(0x1111 / 65535.0, 0x2222 / 65535.0, 0x3333 / 65535.0))
  }

  func testDeviceAttributesReplyEndsTheQueryEarly() {
    var reader = TerminalColorReplyReader(expectsPalette: true)
    let rex = "\u{1b}]4;0;rgb:1d1d/1f1f/2121\(st)\u{1b}[?997;1n\u{1b}[?62;2"
    reader.feed(Array(rex.utf8))
    XCTAssertFalse(reader.isComplete)
    reader.feed(Array("2c".utf8))
    XCTAssertTrue(reader.isComplete)
    XCTAssertTrue(reader.terminalFinishedReplying)
    XCTAssertNil(reader.colors.background)
    XCTAssertEqual(reader.colors.palette[0], RGB(hex: 0x1d1f21))
    XCTAssertEqual(reader.colors.colorScheme, .dark)
  }

  func testReaderIgnoresOtherCSIReplies() {
    var reader = TerminalColorReplyReader(expectsPalette: false)
    reader.feed(Array("\u{1b}[?997;3n\u{1b}[12;40R\u{1b}[c\u{1b}[>1;10;0c".utf8))
    XCTAssertNil(reader.colors.colorScheme)
    XCTAssertFalse(reader.isComplete)
  }

  func testTruncatedCSIDoesNotSwallowColorReply() {
    var reader = TerminalColorReplyReader(expectsPalette: false)
    reader.feed(Array("\u{1b}[?99\u{1b}]11;rgb:12/34/56\(st)\u{1b}[?997;1".utf8))
    XCTAssertEqual(reader.colors.background, RGB(hex: 0x123456))
    reader.feed(Array("n".utf8))
    XCTAssertEqual(reader.colors.colorScheme, .dark)
  }

  func testReaderRecoversFromTruncatedReply() {
    var reader = TerminalColorReplyReader(expectsPalette: false)
    reader.feed(Array("\u{1b}]10;rgb:12\u{1b}[B\u{1b}]10;rgb:ff/ff/ff\(st)".utf8))
    XCTAssertEqual(reader.colors.foreground, RGB(hex: 0xffffff))
  }

  func testReaderIgnoresUnrelatedOSCAndOversizedGarbage() {
    var reader = TerminalColorReplyReader(expectsPalette: false)
    reader.feed(Array("\u{1b}]52;c;aGVsbG8=\(bel)".utf8))
    reader.feed([0x1b, 0x5d] + Array(repeating: 0x41, count: 5000))
    reader.feed(Array("\(bel)\u{1b}]10;rgb:ab/ab/ab\(bel)".utf8))
    XCTAssertEqual(reader.colors.foreground, RGB(hex: 0xababab))
  }

  func testColorSetKeepsFirstReplyAndIgnoresHighPaletteIndices() {
    var colors = TerminalColorSet()
    colors.record(.palette(2), RGB(hex: 0x00ff00))
    colors.record(.palette(2), RGB(hex: 0xff0000))
    colors.record(.palette(200), RGB(hex: 0xff0000))
    XCTAssertEqual(colors.palette[2], RGB(hex: 0x00ff00))
    XCTAssertEqual(colors.palette.count, 16)
  }

  private func fullReply(skipping skipped: Int? = nil) -> String {
    var reply = "\u{1b}]10;rgb:d4d4/d4d4/d4d4\(st)\u{1b}]11;rgb:1e1e/1e1e/1e1e\(bel)\u{1b}[?997;1n"
    for index in 0..<16 where index != skipped {
      let channel = String(format: "%02x", index)
      reply += "\u{1b}]4;\(index);rgb:\(channel)/\(channel)/\(channel)\(index.isMultiple(of: 2) ? st : bel)"
    }
    return reply
  }
}
