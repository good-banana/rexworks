import CoreGraphics
import MDViewerCore
import XCTest

@testable import MDViewerRender

final class StatusHintsTests: XCTestCase {
  private let palette = RenderPalette.fallback(dark: true)

  private func inkedPixels(_ bitmap: RasterBitmap, in rect: CGRect) -> Int {
    let background = palette.statusBarBackground.pixel
    var count = 0
    for y in Int(rect.minY.rounded(.up))..<Int(rect.maxY.rounded(.down)) {
      for x in Int(rect.minX.rounded(.up))..<Int(rect.maxX.rounded(.down)) {
        if let pixel = bitmap.pixel(x: x, y: y), pixel.distance(to: background) > 40 { count += 1 }
      }
    }
    return count
  }

  func testHintsAndRefreshAlwaysFitAndThePathYields() throws {
    let content = StatusBarContent(
      fileName: "a-very-long-file-name-that-would-never-fit-in-a-narrow-pane.md",
      folder: "~/Documents/projects/team-notes/drafts/screenshots/visual-check",
      progress: ScrollProgress(start: 0, fraction: 0.5), message: StatusMessage("3/14", kind: .find))
    for width in [420, 640, 1600] {
      let bar = StatusBar(palette: palette, backingScale: 2)
      let rect = CGRect(x: 0, y: 0, width: width, height: 44)
      let bitmap = try XCTUnwrap(RasterBitmap(width: width, height: 44))
      bar.draw(content, in: rect, bitmap: bitmap)
      let hints = bar.keyHintsRect(in: rect)
      let refresh = bar.refreshButton(in: rect)
      XCTAssertGreaterThanOrEqual(hints.minX, 0, "the hints fit at \(width) px")
      XCTAssertLessThanOrEqual(hints.maxX, refresh.minX, "the hints sit left of the refresh button")
      XCTAssertLessThanOrEqual(refresh.maxX, rect.maxX)
      XCTAssertGreaterThan(inkedPixels(bitmap, in: hints), 40, "the hints are drawn at \(width) px")
      XCTAssertGreaterThan(inkedPixels(bitmap, in: refresh), 10, "the refresh control is drawn at \(width) px")
    }
  }

  func testWithoutRoomForAnyPathTheHintsStillDraw() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 360, height: 44)
    let bitmap = try XCTUnwrap(RasterBitmap(width: 360, height: 44))
    bar.draw(
      StatusBarContent(fileName: "x.md", folder: "~/a", progress: ScrollProgress(start: 0, fraction: 1)), in: rect,
      bitmap: bitmap)
    XCTAssertGreaterThan(inkedPixels(bitmap, in: bar.keyHintsRect(in: rect)), 40)
  }

  func testHelpOverlayDrawsAPanelOverTheContent() throws {
    let overlay = HelpOverlay(palette: palette, backingScale: 2)
    let area = CGRect(x: 0, y: 0, width: 1400, height: 1200)
    let bitmap = try XCTUnwrap(RasterBitmap(width: 1400, height: 1200))
    bitmap.context.setFillColor(palette.pageBackground.cgColor)
    bitmap.context.fill(CGRect(x: 0, y: 0, width: 1400, height: 1200))
    overlay.draw(in: area, clip: area, bitmap: bitmap)
    let panel = overlay.panel(in: area)
    XCTAssertTrue(area.contains(panel))
    let inside = try XCTUnwrap(bitmap.pixel(x: Int(panel.maxX) - 12, y: Int(panel.maxY) - 12))
    XCTAssertLessThanOrEqual(inside.distance(to: palette.statusBarBackground.pixel), 3)
    XCTAssertGreaterThan(HelpOverlay.entries.count, 15)
    XCTAssertTrue(HelpOverlay.entries.contains { $0.keys.contains("?") })
  }

  func testHelpOverlayPatchMatchesTheFullDraw() throws {
    let overlay = HelpOverlay(palette: palette, backingScale: 2)
    let area = CGRect(x: 0, y: 0, width: 1000, height: 900)
    let full = try XCTUnwrap(RasterBitmap(width: 1000, height: 900))
    overlay.draw(in: area, clip: area, bitmap: full)
    let patchRect = CGRect(x: 300, y: 200, width: 240, height: 160)
    let patch = try XCTUnwrap(RasterBitmap(width: 240, height: 160))
    overlay.draw(in: area, clip: patchRect, origin: patchRect.origin, bitmap: patch)
    for (x, y) in [(10, 10), (120, 80), (230, 150)] {
      XCTAssertEqual(patch.pixel(x: x, y: y), full.pixel(x: 300 + x, y: 200 + y))
    }
  }
}
