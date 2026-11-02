import CoreGraphics
import MDViewerDocument
import XCTest

@testable import MDViewerLayout

final class PercentImageTests: XCTestCase {
  private let sizes: @Sendable (String) -> CGSize? = { _ in CGSize(width: 1520, height: 3896) }

  private func page(_ markdown: String) -> PageLayout {
    prepare(markdown).layout(LayoutInput(width: 1200, imageSize: sizes))
  }

  func testTwoHalfWidthImagesSitSideBySideAndCenter() throws {
    let layout = page(
      "<p align=\"center\">\n  <img src=\"a.png\" width=\"49%\">\n  <img src=\"b.png\" width=\"49%\">\n</p>")
    XCTAssertEqual(layout.images.count, 2)
    let (first, second) = (layout.images[0].rect, layout.images[1].rect)
    XCTAssertEqual(first.minY, second.minY, accuracy: 0.5, "one line")
    XCTAssertEqual(first.width, layout.contentWidth * 0.49, accuracy: 1)
    XCTAssertEqual(second.width, first.width, accuracy: 0.5)
    XCTAssertEqual(first.height, first.width * 3896 / 1520, accuracy: 1, "the height follows the aspect ratio")
    XCTAssertGreaterThan(second.minX, first.maxX)
    let left = first.minX - layout.contentLeft
    let right = layout.contentLeft + layout.contentWidth - second.maxX
    XCTAssertEqual(left, right, accuracy: 2, "the line is centered")
    XCTAssertTrue(layout.images.allSatisfy(\.hasIntrinsicSize))
  }

  func testThreeHalfWidthImagesWrapToTwoLines() {
    let layout = page(
      "<p>\n<img src=\"a.png\" width=\"49%\">\n<img src=\"b.png\" width=\"49%\">\n<img src=\"c.png\" width=\"49%\">\n</p>"
    )
    let tops = layout.images.map(\.rect.minY)
    XCTAssertEqual(tops[0], tops[1], accuracy: 0.5)
    XCTAssertGreaterThan(tops[2], layout.images[0].rect.maxY - 0.5, "the third wraps below")
    XCTAssertEqual(layout.images[2].rect.minX, layout.contentLeft, accuracy: 0.5)
  }

  func testPercentageHeightAndPixelWidthsStillWork() {
    let layout = page("<img src=\"a.png\" width=\"50%\" height=\"25%\"> <img src=\"b.png\" width=\"100\">")
    let typography = layout.prepared.typography
    XCTAssertEqual(layout.images[0].rect.width, layout.contentWidth * 0.5, accuracy: 1)
    XCTAssertEqual(layout.images[0].rect.height, layout.contentWidth * 0.25, accuracy: 1)
    XCTAssertEqual(layout.images[1].rect.width, typography.pixels(cssPoints: 100), accuracy: 0.5)
  }

  func testAnImageAloneInAParagraphIsUnchanged() {
    let layout = page("![shot](a.png)")
    let box = layout.images[0].rect
    XCTAssertEqual(
      box.width, min(layout.prepared.typography.pixels(cssPoints: 1520), layout.contentWidth), accuracy: 0.5)
    XCTAssertEqual(box.minX, layout.contentLeft, accuracy: 0.5)
  }
}
