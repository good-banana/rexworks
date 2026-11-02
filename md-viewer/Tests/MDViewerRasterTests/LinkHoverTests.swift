import CoreGraphics
import MDViewerCore
import MDViewerLayout
import XCTest

@testable import MDViewerRender

final class LinkHoverTests: XCTestCase {
  private func count(_ bitmap: RasterBitmap, _ color: RGB, in rect: CGRect, tolerance: Int = 6) -> Int {
    var total = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
      for x in Int(rect.minX)..<Int(rect.maxX) {
        if let pixel = bitmap.pixel(x: x, y: y), pixel.distance(to: color.pixel) <= tolerance { total += 1 }
      }
    }
    return total
  }

  func testHoverColorsAndUnderlinesEveryFragmentOfTheLink() throws {
    for dark in [true, false] {
      let palette = RenderPalette.fallback(dark: dark)
      XCTAssertNotEqual(palette.linkHover, palette.link)
      XCTAssertGreaterThanOrEqual(palette.linkHover.contrast(with: palette.pageBackground), RenderPalette.textContrast)
      XCTAssertEqual(
        palette.linkHover.relativeLuminance > palette.link.relativeLuminance, dark,
        "lighter on dark themes, darker on light themes")
      let page = prepare(
        "Intro [a link that is long enough to wrap onto the next line in a narrow view](https://example.com) end."
      ).layout(width: 700)
      let range = try XCTUnwrap(page.prepared.links.first?.range)
      let rects = page.rects(for: range).map(\.rect)
      XCTAssertGreaterThan(Set(rects.map(\.minY)).count, 1)
      let rasterizer = Rasterizer(layout: page, palette: palette)
      let area = CGRect(x: 0, y: 0, width: page.width, height: page.height)
      let plain = try XCTUnwrap(rasterizer.render(area))
      let hovered = try XCTUnwrap(rasterizer.render(area, overlay: RenderOverlay(hoverLink: range)))
      for rect in rects {
        let band = rect.insetBy(dx: 0, dy: -4)
        XCTAssertEqual(count(plain, palette.linkHover, in: band), 0, "no hover style without hover")
        XCTAssertGreaterThan(count(hovered, palette.linkHover, in: band), Int(rect.width), "fragment \(rect)")
        let underline = CGRect(
          x: rect.minX + 2, y: rect.maxY - rect.height * 0.35, width: rect.width - 4, height: rect.height * 0.35 + 4)
        XCTAssertGreaterThan(
          count(hovered, palette.linkHover, in: underline, tolerance: 10), Int(rect.width * 0.8),
          "an underline runs along fragment \(rect)")
      }
    }
  }
}
