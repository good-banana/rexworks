import MDViewerDocument
import XCTest

final class AlertTests: XCTestCase {
  func alert(_ markdown: String) -> Alert? {
    Document.parse(markdown).blocks.first?.alert
  }

  func testEveryKind() {
    for kind in AlertKind.allCases {
      let parsed = alert("> [!\(kind.rawValue.uppercased())]\n> Body for \(kind.rawValue).\n")
      XCTAssertEqual(parsed?.kind, kind)
      XCTAssertEqual(parsed.map { shape($0.blocks[0].paragraph ?? []) }, "\"Body for \(kind.rawValue).\"")
    }
    XCTAssertEqual(AlertKind.allCases.map(\.title), ["Note", "Tip", "Important", "Warning", "Caution"])
  }

  func testFixtureAlert() throws {
    let document = Document.parse(try fixture("all-nodes"))
    let warning = try XCTUnwrap(document.blocks[9].alert)
    XCTAssertEqual(warning.kind, .warning)
    XCTAssertEqual(shape(warning.blocks[0].paragraph ?? []), "\"Watch out.\"")
    XCTAssertEqual(document.blocks[9].range.start, SourcePosition(line: 31, column: 1))
  }

  func testMarkerIsCaseInsensitiveAndAllowsTrailingBlanks() {
    XCTAssertEqual(alert("> [!tip]\n> Lower.\n")?.kind, .tip)
    XCTAssertEqual(alert("> [!Note] \t\n> Mixed.\n")?.kind, .note)
    XCTAssertEqual(
      alert("> [!NOTE]  \n> Hard break after marker.\n").map { shape($0.blocks[0].paragraph ?? []) },
      "\"Hard break after marker.\"")
    XCTAssertEqual(alert("> [!NOTE]\r\n> CRLF.\r\n")?.kind, .note)
  }

  func testMarkerOnlyDropsEmptyParagraph() {
    let parsed = alert("> [!CAUTION]\n")
    XCTAssertEqual(parsed?.kind, .caution)
    XCTAssertEqual(parsed?.blocks, [])
    let withBlocks = alert("> [!IMPORTANT]\n>\n> Second paragraph.\n")
    XCTAssertEqual(withBlocks?.blocks.compactMap(\.paragraph).map(shape), ["\"Second paragraph.\""])
  }

  func testNonAlertsStayBlockQuotes() {
    for markdown in [
      "> [!NOTE] same line\n",
      "> [!UNKNOWN]\n> Body\n",
      "> Text first\n> [!NOTE]\n",
      "> - [!NOTE]\n",
      "> \\[!NOTE]\n> Escaped\n",
      "> [ !NOTE]\n",
    ] {
      let blocks = Document.parse(markdown).blocks
      XCTAssertNil(blocks.first?.alert, markdown)
      XCTAssertNotNil(blocks.first?.quote, markdown)
    }
  }

  func testNestedAlertsInsideOtherContainers() throws {
    let list = try XCTUnwrap(Document.parse("- item\n\n  > [!TIP]\n  > Nested.\n").blocks.first?.list)
    XCTAssertEqual(list.items[0].blocks[1].alert?.kind, .tip)
    let quote = try XCTUnwrap(Document.parse("> > [!NOTE]\n> > Deep.\n").blocks.first?.quote)
    XCTAssertEqual(quote[0].alert?.kind, .note)
  }
}
