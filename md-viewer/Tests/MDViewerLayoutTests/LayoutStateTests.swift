import CoreGraphics
import MDViewerDocument
import XCTest

@testable import MDViewerLayout

final class LayoutStateTests: XCTestCase {
  private let detailsMarkdown = """
    Before.

    <details>
    <summary>Summary line</summary>

    ## Inner heading

    Hidden body text.

    </details>

    After.
    """

  func testDetailsToggleChangesTheLayout() throws {
    let prepared = prepare(detailsMarkdown)
    XCTAssertTrue(prepared.initiallyExpandedDetails.isEmpty)
    let collapsed = prepared.layout(width: 1000)
    guard case .detailsToggle(let id)? = collapsed.targets.first?.target else { return XCTFail("no toggle") }
    let expanded = prepared.layout(LayoutInput(width: 1000, expandedDetails: [id]))
    XCTAssertGreaterThan(expanded.height, collapsed.height)
    XCTAssertTrue(collapsed.lineTops(for: "Hidden").isEmpty)
    XCTAssertFalse(expanded.lineTops(for: "Hidden").isEmpty)
    XCTAssertEqual(collapsed.decorations { $0 == .disclosure(expanded: false) }.count, 1)
    XCTAssertEqual(expanded.decorations { $0 == .disclosure(expanded: true) }.count, 1)
    let all = 0..<prepared.text.length
    XCTAssertEqual(collapsed.plainText(all), "Before.\n\nSummary line\n\nAfter.")
    XCTAssertEqual(expanded.plainText(all), "Before.\n\nSummary line\n\nInner heading\n\nHidden body text.\n\nAfter.")
    XCTAssertTrue(collapsed.find("hidden").isEmpty)
    XCTAssertEqual(expanded.find("hidden").count, 1)

    let anchor = try XCTUnwrap(collapsed.anchorPosition("#inner-heading"))
    XCTAssertEqual(anchor.collapsedDetails, [id])
    XCTAssertEqual(anchor.y, collapsed.lineTops(for: "Summary line").first)
    let open = try XCTUnwrap(expanded.anchorPosition("#inner-heading"))
    XCTAssertEqual(open.collapsedDetails, [])
    XCTAssertEqual(open.y, expanded.lineTops(for: "Inner heading").first)
  }

  func testDetailsOpenAttributeSeedsTheExpandedSet() {
    let prepared = prepare("<details open>\n<summary>S</summary>\n\nBody.\n\n</details>")
    XCTAssertEqual(prepared.initiallyExpandedDetails.count, 1)
    XCTAssertFalse(prepared.layout(width: 900).lineTops(for: "Body.").isEmpty)
  }

  func testPictureVariantFollowsPrefersDark() throws {
    let markdown = try fixture("readme")
    let prepared = prepare(markdown)
    let light = prepared.layout(LayoutInput(width: 1200, prefersDark: false))
    let dark = prepared.layout(LayoutInput(width: 1200, prefersDark: true))
    XCTAssertEqual(light.images.first?.content, .image(source: "docs/logo-light.png"))
    XCTAssertEqual(dark.images.first?.content, .image(source: "docs/logo-dark.png"))
    let logo = try XCTUnwrap(light.images.first)
    XCTAssertEqual(logo.rect.width, 240 * prepared.typography.scale, accuracy: 0.01)
    XCTAssertEqual(logo.rect.midX, light.contentLeft + light.contentWidth / 2, accuracy: 1)
  }

  func testColumnSizingRules() {
    let sizing = ColumnSizing(minimum: [10, 20, 30], maximum: [50, 40, 30])
    XCTAssertEqual(sizing.widths(available: 200), [50, 40, 30])
    XCTAssertEqual(sizing.widths(available: 40), [10, 20, 30])
    let between = sizing.widths(available: 90)
    XCTAssertEqual(between.reduce(0, +), 90, accuracy: 0.001)
    XCTAssertEqual(between[0], 10 + 40 * 30 / 60, accuracy: 0.001)
    XCTAssertEqual(between[2], 30)
  }

  func testTableColumnsWrapButNeverShrinkBelowMinContent() throws {
    let markdown = """
      | Name | Description | Value |
      | :--- | :---: | ---: |
      | alpha | a fairly long description that will need to wrap inside its cell at narrow widths | 42 |
      | beta | short | 7 |
      """
    let prepared = prepare(markdown)
    let wide = prepared.layout(width: 3000)
    let narrow = prepared.layout(width: 900)
    let tiny = prepared.layout(width: 300)
    XCTAssertTrue(wide.regions.isEmpty)
    XCTAssertTrue(narrow.regions.isEmpty)
    let cellText = "a fairly long description that will need to wrap inside its cell at narrow widths"
    XCTAssertGreaterThan(narrow.lineTops(for: cellText).count, 1)
    XCTAssertEqual(wide.lineTops(for: "a fairly long description that will need").count, 1)
    let tableRegion = try XCTUnwrap(tiny.regions.first)
    XCTAssertGreaterThan(tableRegion.contentWidth, tableRegion.rect.width)
    for word in ["Description", "description", "narrow"] {
      XCTAssertEqual(tiny.lineTops(for: word).count, 1)
      XCTAssertFalse(tiny.fragments(in: try XCTUnwrap(tiny.range(of: word))).contains(where: \.isClipped))
    }
    let borders = narrow.decorations { $0 == .tableCellBorder }
    let valueCell = try XCTUnwrap(borders.first { $0.rect.contains(try XCTUnwrap(narrow.center(of: "42"))) })
    let value = try XCTUnwrap(narrow.rects(for: XCTUnwrap(narrow.range(of: "42"))).first).rect
    let padding = prepared.typography.pixels(em: prepared.typography.tableCellPadding.width)
    XCTAssertEqual(value.maxX, valueCell.rect.maxX - padding, accuracy: 1)
    let shortCell = try XCTUnwrap(borders.first { $0.rect.contains(try XCTUnwrap(narrow.center(of: "short"))) })
    XCTAssertEqual(try XCTUnwrap(narrow.center(of: "short")).x, shortCell.rect.midX, accuracy: 1)
    XCTAssertEqual(narrow.decorations { $0 == .tableHeaderFill }.count, 1)
    XCTAssertEqual(narrow.decorations { $0 == .tableStripe }.count, 1)
  }

  func testHTMLTableSpans() throws {
    let page = layout(try fixture("readme"), width: 1400)
    let spanning = try XCTUnwrap(page.center(of: "More platforms"))
    let borders = page.decorations { $0 == .tableCellBorder }
    let cell = try XCTUnwrap(borders.first { $0.rect.contains(spanning) })
    let platform = try XCTUnwrap(borders.first { $0.rect.contains(try XCTUnwrap(page.center(of: "Platform"))) })
    let command = try XCTUnwrap(borders.first { $0.rect.contains(try XCTUnwrap(page.center(of: "Command"))) })
    XCTAssertEqual(cell.rect.width, platform.rect.width + command.rect.width, accuracy: 0.5)
  }

  func testZoomScalesGeometry() throws {
    let markdown = try fixture("sample")
    let base = PreparedDocument(markdown: markdown, typography: Typography(zoom: 1)).layout(width: 1000)
    let zoomed = PreparedDocument(markdown: markdown, typography: Typography(zoom: 2)).layout(width: 2000)
    XCTAssertEqual(zoomed.height / base.height, 2, accuracy: 0.05)
    let a = try XCTUnwrap(base.rects(for: XCTUnwrap(base.range(of: "Goals"))).first).rect
    let b = try XCTUnwrap(zoomed.rects(for: XCTUnwrap(zoomed.range(of: "Goals"))).first).rect
    XCTAssertEqual(b.minX / a.minX, 2, accuracy: 0.02)
    XCTAssertEqual(b.minY / a.minY, 2, accuracy: 0.05)
    XCTAssertEqual(b.height / a.height, 2, accuracy: 0.05)
    var custom = Typography(bodySize: 16, zoom: 1.5, backingScale: 1)
    custom.blockSpacing = 2
    XCTAssertEqual(custom.bodyPixelSize, 24)
    XCTAssertEqual(custom.pixels(em: custom.blockSpacing), 48)
    XCTAssertEqual(Typography.backingScale(cellPixelHeight: 33, screenScale: nil), 2)
    XCTAssertEqual(Typography.backingScale(cellPixelHeight: 16, screenScale: nil), 1)
    XCTAssertEqual(Typography.backingScale(cellPixelHeight: 16, screenScale: 3), 3)
  }

  func testBreakRangesHaveNoTraps() throws {
    let markdown = "x  \ny\nz\\\nw"
    let page = layout(markdown)
    let all = 0..<page.prepared.text.length
    XCTAssertEqual(page.plainText(all), "x\ny z\nw")
    let whole = try XCTUnwrap(page.sourceRange(for: all))
    XCTAssertEqual(whole.start, SourcePosition(line: 1, column: 1))
    XCTAssertEqual(whole.end.line, 4)
    let breakOffset = try XCTUnwrap(page.range(of: "\n")).lowerBound
    let breakSource = try XCTUnwrap(page.sourceRange(for: breakOffset..<(breakOffset + 1)))
    XCTAssertTrue(breakSource.isEmpty)
    XCTAssertEqual(breakSource.start.line, 1)
    let soft = try XCTUnwrap(page.range(of: " ", occurrence: 0))
    XCTAssertTrue(try XCTUnwrap(page.sourceRange(for: soft)).isEmpty)
    for offset in 0...page.prepared.text.length {
      _ = page.sourceRange(for: offset..<offset)
      _ = page.markdown(offset..<offset)
      _ = page.rects(for: offset..<min(offset + 1, page.prepared.text.length))
    }
    XCTAssertEqual(page.markdown(all), markdown)
  }

  func testAnchorsResolveToYPositions() throws {
    let markdown = """
      # Title

      Some text with <a name="custom-spot"></a>an anchor.

      ## Second Section

      Body.
      """
    let page = layout(markdown)
    XCTAssertEqual(page.anchorPosition("#title")?.y, page.lineTops(for: "Title").first)
    XCTAssertEqual(page.anchorPosition("#second-section")?.y, page.lineTops(for: "Second Section").first)
    XCTAssertEqual(page.anchorPosition("#user-content-second-section")?.y, page.lineTops(for: "Second Section").first)
    XCTAssertEqual(page.anchorPosition("custom-spot")?.y, page.lineTops(for: "an anchor").first)
    XCTAssertNil(page.anchorPosition("#missing"))
    XCTAssertEqual(page.prepared.anchorNames, ["title", "second-section", "custom-spot"])
  }

  func testReflowIsStable() throws {
    let prepared = prepare(try fixture("sample"))
    let first = prepared.layout(width: 1234)
    XCTAssertEqual(first, prepared.layout(width: 1234))
    _ = prepared.layout(width: 640)
    XCTAssertEqual(first, prepared.layout(width: 1234))
    XCTAssertNotEqual(first, prepared.layout(width: 1300))
  }

  func testBlockIDsAreStableAcrossLayouts() throws {
    let prepared = prepare(try fixture("sample"))
    let narrow = prepared.layout(width: 600)
    let wide = prepared.layout(width: 1800)
    let offset = try XCTUnwrap(narrow.range(of: "reindex_all")).lowerBound
    XCTAssertEqual(narrow.block(containing: offset), wide.block(containing: offset))
    XCTAssertEqual(
      PreparedDocument(markdown: try fixture("sample")).units.map(\.block), prepared.units.map(\.block))
  }
}
