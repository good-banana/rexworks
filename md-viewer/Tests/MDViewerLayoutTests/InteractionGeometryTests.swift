import CoreGraphics
import MDViewerDocument
import XCTest

@testable import MDViewerLayout

final class InteractionGeometryTests: XCTestCase {
  func testPointToTextToRectsRoundTrips() throws {
    let page = layout(try fixture("sample"), width: 1400)
    for needle in ["Search indexing rollout", "streaming pipeline guide", "reindex_all", "Batch job", "write_mode"] {
      let range = try XCTUnwrap(page.range(of: needle), needle)
      let rects = page.rects(for: range)
      XCTAssertFalse(rects.isEmpty, needle)
      for rect in rects {
        let position = try XCTUnwrap(page.textPosition(at: CGPoint(x: rect.rect.midX, y: rect.rect.midY)))
        XCTAssertTrue(range.contains(position.offset), "\(needle) \(position.offset) \(range)")
        XCTAssertEqual(position.block, page.block(containing: range.lowerBound))
      }
      let start = try XCTUnwrap(page.textPosition(at: CGPoint(x: rects[0].rect.minX + 0.5, y: rects[0].rect.midY)))
      XCTAssertEqual(start.offset, range.lowerBound, needle)
    }
  }

  func testHitTargets() throws {
    let markdown = """
      See [the guide](https://example.com/guide) here.

      - [ ] task

      ```
      code
      ```

      <details>
      <summary>More</summary>

      Hidden body.

      </details>
      """
    let page = layout(markdown)
    let link = try XCTUnwrap(page.center(of: "the guide"))
    XCTAssertEqual(page.hit(link).target, .link("https://example.com/guide"))
    XCTAssertNil(page.target(at: try XCTUnwrap(page.center(of: "See"))))
    let task = try XCTUnwrap(page.targets.first { if case .task = $0.target { return true } else { return false } })
    XCTAssertEqual(page.target(at: CGPoint(x: task.rect.midX, y: task.rect.midY)), task.target)
    let copy = try XCTUnwrap(page.targets.first { if case .copyCode = $0.target { return true } else { return false } })
    XCTAssertEqual(page.target(at: CGPoint(x: copy.rect.midX, y: copy.rect.midY)), copy.target)
    let summary = try XCTUnwrap(page.center(of: "More"))
    guard case .detailsToggle = page.target(at: summary) else { return XCTFail("summary is not a toggle") }
  }

  func testSelectionPlainTextAndMarkdown() throws {
    let page = layout(try fixture("sample"), width: 1400)
    let start = try XCTUnwrap(page.range(of: "Retire the nightly"))
    let end = try XCTUnwrap(page.range(of: "Streaming (staging)"))
    let selection = start.lowerBound..<end.upperBound
    let plain = page.plainText(selection)
    XCTAssertTrue(plain.hasPrefix("Retire the nightly reindex_all cron job\nKeep search results identical"))
    XCTAssertTrue(plain.hasSuffix("Metric\tBatch job\tStreaming (staging)"), plain)
    let markdown = page.markdown(selection)
    XCTAssertTrue(markdown.hasPrefix("- Retire the nightly `reindex_all` cron job"), markdown)
    XCTAssertTrue(markdown.hasSuffix("| Failed documents | 0.4% | 0.1% |"), markdown)
    XCTAssertTrue(markdown.contains("## Current state\n\nThe batch job"), markdown)
    let frontMatter = try XCTUnwrap(page.range(of: "status"))
    XCTAssertTrue(page.markdown(frontMatter).hasPrefix("---\ntitle: Search indexing rollout"))
  }

  func testWordAndUnitRanges() throws {
    let page = layout("Alpha beta_gamma delta.\n\nNext paragraph.")
    let inside = try XCTUnwrap(page.range(of: "gamma")).lowerBound
    XCTAssertEqual(page.plainText(page.wordRange(at: inside)), "beta_gamma")
    XCTAssertEqual(page.plainText(page.unitRange(at: inside)), "Alpha beta_gamma delta.")
  }

  func testFindReturnsRangesAndRects() throws {
    let page = layout(try fixture("sample"), width: 1400)
    let matches = page.find("index")
    XCTAssertGreaterThan(matches.count, 5)
    for match in matches {
      XCTAssertEqual(page.plainText(match.range).lowercased(), "index")
      if page.fragments(in: match.range).isEmpty == false { XCTAssertFalse(match.rects.isEmpty) }
    }
    XCTAssertTrue(page.find("").isEmpty)
    XCTAssertEqual(page.find("SHADOW").count, page.find("shadow").count)
  }

  func testWideCodeBlockBecomesScrollRegion() throws {
    let long = "let value = " + String(repeating: "something + ", count: 40) + "end"
    let markdown = "```\n\(long)\nshort\n```"
    let prepared = prepare(markdown)
    let page = prepared.layout(width: 800)
    let region = try XCTUnwrap(page.regions.first)
    XCTAssertEqual(region.rect.width, page.contentWidth, accuracy: 0.01)
    XCTAssertGreaterThan(region.contentWidth, region.rect.width)
    XCTAssertEqual(region.offset, 0)
    XCTAssertEqual(page.scrollRegion(at: CGPoint(x: region.rect.midX, y: region.rect.midY)), region.id)
    XCTAssertTrue(page.fragments.allSatisfy { $0.region == region.id })
    XCTAssertEqual(Set(page.fragments.map(\.lineTop)).count, 2)

    let range = try XCTUnwrap(page.range(of: "end"))
    let target = try XCTUnwrap(page.range(of: "something", occurrence: 2))
    let unscrolled = try XCTUnwrap(page.rects(for: target).first).rect
    let scrolled = prepared.layout(LayoutInput(width: 800, scrollOffsets: [region.id: 120]))
    XCTAssertEqual(scrolled.region(region.id)?.offset, 120)
    let moved = try XCTUnwrap(scrolled.rects(for: target).first).rect
    XCTAssertEqual(moved.minX, unscrolled.minX - 120, accuracy: 0.01)
    XCTAssertTrue(scrolled.rects(for: try XCTUnwrap(scrolled.range(of: "let"))).isEmpty)
    let probe = CGPoint(x: unscrolled.minX + 200, y: unscrolled.midY)
    let before = try XCTUnwrap(page.textPosition(at: probe)).offset
    let after = try XCTUnwrap(scrolled.textPosition(at: probe)).offset
    XCTAssertGreaterThan(after, before)

    let clamped = prepared.layout(LayoutInput(width: 800, scrollOffsets: [region.id: 1e6]))
    let maximum = try XCTUnwrap(clamped.region(region.id))
    XCTAssertEqual(maximum.offset, maximum.maxOffset, accuracy: 0.01)
    let end = try XCTUnwrap(clamped.rects(for: range).last).rect
    XCTAssertLessThanOrEqual(end.maxX, region.rect.maxX + 0.5)
  }

  func testWideTableScrollsAndCopyTargetIgnoresOffset() throws {
    let header = (1...8).map { "Column header number \($0)" }.joined(separator: " | ")
    let row = (1...8).map { "value\($0)" }.joined(separator: " | ")
    let markdown = "| \(header) |\n|\(String(repeating: " --- |", count: 8))\n| \(row) |"
    let prepared = prepare(markdown)
    let page = prepared.layout(width: 900)
    let region = try XCTUnwrap(page.regions.first)
    let shifted = prepared.layout(LayoutInput(width: 900, scrollOffsets: [region.id: 300]))
    let fill = try XCTUnwrap(shifted.decorations { $0 == .tableHeaderFill }.first)
    XCTAssertEqual(fill.region, region.id)
    XCTAssertEqual(shifted.displayRect(fill.rect, region: fill.region).minX, fill.rect.minX - 300)
    let hidden = try XCTUnwrap(shifted.range(of: "Column header number 1"))
    XCTAssertTrue(shifted.rects(for: hidden).allSatisfy { $0.rect.minX >= region.rect.minX })
  }
}
