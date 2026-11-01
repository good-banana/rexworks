import XCTest

@testable import MDViewerCore

final class MarkdownTextTests: XCTestCase {
  func testDecodesUTF8() {
    XCTAssertEqual(decodeMarkdown(Data("# caf\u{e9} \u{1F600}".utf8)), "# caf\u{e9} \u{1F600}")
  }

  func testFallsBackToWindows1252() {
    let bytes: [UInt8] = [0x23, 0x20, 0x93, 0x63, 0x61, 0x66, 0xE9, 0x94]
    XCTAssertEqual(decodeMarkdown(Data(bytes)), "# \u{201C}caf\u{e9}\u{201D}")
  }

  func testDecodesBytesUndefinedInWindows1252() {
    let decoded = decodeMarkdown(Data([0x61, 0x81, 0x62]))
    XCTAssertTrue(decoded.hasPrefix("a"))
    XCTAssertTrue(decoded.hasSuffix("b"))
  }

  func testReadMarkdownDecodesLatin1File() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).md")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data([0x23, 0x20, 0x6E, 0xE4, 0x69, 0x76, 0x65]).write(to: file)
    XCTAssertEqual(try readMarkdown(at: file), "# n\u{e4}ive")
  }

  func testReadMarkdownThrowsForMissingFile() {
    XCTAssertThrowsError(try readMarkdown(at: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).md")))
  }
}
