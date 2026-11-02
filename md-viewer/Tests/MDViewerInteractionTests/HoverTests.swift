import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout
import XCTest

@testable import MDViewerInteraction

final class HoverTests: XCTestCase {
  private let text = """
    Intro words before [a link that is long enough to wrap onto the next line in a narrow view](https://example.com) and after.

    ```swift
    let value = 1
    ```
    """

  private func sorted(_ rects: [CGRect]) -> [String] {
    rects.map { "\($0)" }.sorted()
  }

  @discardableResult
  private func hover(_ h: inout Harness, _ point: CGPoint) -> [InteractionEffect] {
    h.mouse(.motion, at: point, button: 3)
  }

  func testShapesFollowWhatIsUnderThePointerAndAreSentOnlyOnChange() {
    var h = Harness(text, width: 700)
    let link = h.point(of: "link")
    XCTAssertTrue(hover(&h, link).contains(.pointerShape(.pointer)))
    XCTAssertFalse(hover(&h, h.point(of: "long")).contains { if case .pointerShape = $0 { true } else { false } })
    XCTAssertEqual(h.model.pointerShape, .pointer)
    XCTAssertTrue(hover(&h, h.point(of: "Intro")).contains(.pointerShape(.text)))
    XCTAssertTrue(hover(&h, CGPoint(x: 5, y: h.point(of: "Intro").y)).contains(.pointerShape(.default)), "margin")
    let copy = h.layout.targets.first { if case .copyCode = $0.target { true } else { false } }!.rect
    h.mouse(.motion, at: CGPoint(x: h.point(of: "value").x, y: h.point(of: "value").y), button: 3)
    XCTAssertTrue(hover(&h, CGPoint(x: copy.midX, y: copy.midY)).contains(.pointerShape(.pointer)), "copy pill")
    let status = h.paneMouse(.motion, x: 20, y: Int(h.model.geometry.contentHeight) + 5, button: 3)
    XCTAssertTrue(status.contains(.pointerShape(.default)), "the status bar uses the default shape")
  }

  func testDetailsSummariesAndHelpShapes() {
    var h = Harness("<details><summary>More</summary>\n\nHidden\n\n</details>\n\nText")
    let toggle = h.layout.targets.first { if case .detailsToggle = $0.target { true } else { false } }!.rect
    XCTAssertTrue(hover(&h, CGPoint(x: toggle.midX, y: toggle.midY)).contains(.pointerShape(.pointer)))
    XCTAssertTrue(h.key(.char("?")).contains(.pointerShape(.default)), "help shows the default shape")
    XCTAssertEqual(hover(&h, CGPoint(x: toggle.midX, y: toggle.midY)), [], "no hover while help shows")
  }

  func testHoveringALinkRedrawsOnlyItsRectsAndStylesEveryFragment() {
    var h = Harness(text, width: 700)
    let range = h.layout.prepared.links.first!.range
    let rects = h.layout.rects(for: range).map(\.rect)
    XCTAssertGreaterThan(Set(rects.map(\.minY)).count, 1, "the link wraps")
    let on = hover(&h, h.point(of: "link"))
    XCTAssertEqual(h.model.overlay.hoverLink, range, "every fragment of the link")
    XCTAssertEqual(sorted(on.redrawRects), sorted(rects))
    XCTAssertFalse(on.contains(.redrawAll))
    XCTAssertEqual(hover(&h, h.point(of: "wrap")).redrawRects, [], "moving within the link redraws nothing")
    let off = hover(&h, h.point(of: "Intro"))
    XCTAssertNil(h.model.overlay.hoverLink)
    XCTAssertEqual(sorted(off.redrawRects), sorted(rects))
  }

  func testReloadsAndNewLayoutsClearTheHoveredLink() {
    var h = Harness(text, width: 700)
    hover(&h, h.point(of: "link"))
    XCTAssertNotNil(h.model.overlay.hoverLink)
    h.run(h.model.fileChanged(source: text + "\n\nMore."))
    XCTAssertNil(h.model.overlay.hoverLink, "a reload drops the stale range")
    hover(&h, h.point(of: "link"))
    XCTAssertNotNil(h.model.overlay.hoverLink)
    h.key(.char("+"))
    XCTAssertNil(h.model.overlay.hoverLink, "a new layout drops it too")
  }
}
