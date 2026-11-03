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

  func testHintsAlwaysFitAndThePathYields() throws {
    XCTAssertEqual(StatusBar.keyHints, "/ find   e edit   r refresh   q quit   ? help")
    let content = StatusBarContent(
      fileName: "a-very-long-file-name-that-would-never-fit-in-a-narrow-pane.md",
      folder: "~/Documents/projects/team-notes/drafts/screenshots/visual-check",
      progress: ScrollProgress(start: 0, fraction: 0.5), message: StatusMessage("3/14", kind: .find))
    for width in [640, 900, 1600] {
      let bar = StatusBar(palette: palette, backingScale: 2)
      let rect = CGRect(x: 0, y: 0, width: width, height: 44)
      let bitmap = try XCTUnwrap(RasterBitmap(width: width, height: 44))
      bar.draw(content, in: rect, bitmap: bitmap)
      let hints = bar.keyHintsRect(in: rect)
      XCTAssertGreaterThanOrEqual(hints.minX, 0, "the hints fit at \(width) px")
      XCTAssertLessThanOrEqual(hints.maxX, rect.maxX)
      XCTAssertGreaterThan(inkedPixels(bitmap, in: hints), 40, "the hints are drawn at \(width) px")
      let right = CGRect(x: hints.maxX + 1, y: 4, width: rect.maxX - hints.maxX - 1, height: 36)
      XCTAssertEqual(inkedPixels(bitmap, in: right), 0, "no refresh control right of the hints at \(width) px")
    }
  }

  func testHintsPickTheWidestTierThatFits() throws {
    XCTAssertEqual(StatusBar.keyHintTiers, ["/ find   e edit   r refresh   q quit   ? help", "e edit   ? help"])
    let bar = StatusBar(palette: palette, backingScale: 2)
    let wide = bar.keyHintsRect(in: CGRect(x: 0, y: 0, width: 1600, height: 44))
    let narrow = bar.keyHintsRect(in: CGRect(x: 0, y: 0, width: 300, height: 44))
    XCTAssertFalse(wide.isNull)
    XCTAssertFalse(narrow.isNull, "the narrow tier fits where the full one does not")
    XCTAssertLessThan(narrow.width, wide.width / 2)
    XCTAssertGreaterThan(wide.width, 300 - 40, "the full tier would not fit at 300 px")
    XCTAssertGreaterThanOrEqual(narrow.minX, 0)
  }

  func testTooNarrowForTheHintsDropsThem() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 150, height: 44)
    let bitmap = try XCTUnwrap(RasterBitmap(width: 150, height: 44))
    bar.draw(
      StatusBarContent(fileName: "x.md", folder: "~/a", progress: ScrollProgress(start: 0, fraction: 1)), in: rect,
      bitmap: bitmap)
    XCTAssertTrue(bar.keyHintsRect(in: rect).isNull)
    XCTAssertGreaterThan(inkedPixels(bitmap, in: CGRect(x: 0, y: 6, width: 120, height: 34)), 20, "the path draws")
  }

  func testTheEditorBadgeIsDrawnAfterTheFileName() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 1600, height: 44)
    let content = StatusBarContent(fileName: "a.md", folder: "~/a", progress: ScrollProgress(start: 0, fraction: 1))
    let plain = try XCTUnwrap(RasterBitmap(width: 1600, height: 44))
    bar.draw(content, in: rect, bitmap: plain)
    var badged = content
    badged.editor = "Neovim: live"
    let withBadge = try XCTUnwrap(RasterBitmap(width: 1600, height: 44))
    bar.draw(badged, in: rect, bitmap: withBadge)
    let middle = CGRect(x: 200, y: 4, width: 400, height: 36)
    XCTAssertEqual(inkedPixels(plain, in: middle), 0)
    XCTAssertGreaterThan(inkedPixels(withBadge, in: middle), 40)
    let path = CGRect(x: 0, y: 4, width: 100, height: 36)
    XCTAssertEqual(inkedPixels(withBadge, in: path), inkedPixels(plain, in: path), "the path is unchanged")
  }

  func testTheEditorBadgeYieldsToTheFileName() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 260, height: 44)
    let content = StatusBarContent(fileName: "a.md", progress: ScrollProgress(start: 0, fraction: 1))
    let plain = try XCTUnwrap(RasterBitmap(width: 260, height: 44))
    bar.draw(content, in: rect, bitmap: plain)
    var badged = content
    badged.editor = "Sublime Text: on save, with a very long name"
    let withBadge = try XCTUnwrap(RasterBitmap(width: 260, height: 44))
    bar.draw(badged, in: rect, bitmap: withBadge)
    XCTAssertEqual(
      inkedPixels(withBadge, in: CGRect(x: 0, y: 4, width: 260, height: 36)),
      inkedPixels(plain, in: CGRect(x: 0, y: 4, width: 260, height: 36)), "a badge that does not fit is left out")
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
    XCTAssertGreaterThan(HelpOverlay.entries(editMode: .split).count, 15)
    XCTAssertTrue(HelpOverlay.entries(editMode: .split).contains { $0.keys.contains("?") })
  }

  func testHelpEntriesFollowTheEditMode() {
    func action(_ keys: String, _ mode: EditMode) -> String? {
      HelpOverlay.entries(editMode: mode).first { $0.keys == keys }?.action
    }
    XCTAssertEqual(action("e", .split), "Edit beside the preview")
    XCTAssertEqual(action("E", .split), "Edit in this pane")
    XCTAssertEqual(action("e", .here), "Edit in this pane")
    XCTAssertEqual(action("E", .here), "Edit beside the preview")
    XCTAssertEqual(action(",", .split), "Choose the editor")
    XCTAssertEqual(
      action("Click", .here),
      "Follow links, toggle details, press Copy, open videos; with Neovim beside, jump the editor")
    XCTAssertEqual(
      HelpOverlay(palette: palette, backingScale: 2, editMode: .here).entries.map(\.action),
      HelpOverlay.entries(editMode: .here).map(\.action))
  }

  func testLongHelpActionsWrapInsteadOfTruncating() {
    let overlay = HelpOverlay(palette: palette, backingScale: 2)
    let width = overlay.panel(in: CGRect(x: 0, y: 0, width: 1400, height: 3000)).width
    let rows = overlay.rows(width: width)
    let click = rows.first { $0.keys == "Click" }
    XCTAssertEqual(click?.lines.count, 2)
    XCTAssertEqual(
      click?.lines.joined(separator: " "),
      "Follow links, toggle details, press Copy, open videos; with Neovim beside, jump the editor")
    XCTAssertEqual(rows.first { $0.keys == "e" }?.lines, ["Edit beside the preview"])
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

  private func fieldFillPixels(_ bitmap: RasterBitmap) -> Int {
    var count = 0
    for y in 6..<bitmap.height {
      for x in 0..<bitmap.width {
        if let pixel = bitmap.pixel(x: x, y: y), pixel.distance(to: palette.pageBackground.pixel) <= 1 { count += 1 }
      }
    }
    return count
  }

  func testTheFindFieldIsDrawnOnlyWhileSearching() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 900, height: 44)
    let progress = ScrollProgress(start: 0, fraction: 1)
    let idle = try XCTUnwrap(RasterBitmap(width: 900, height: 44))
    bar.draw(StatusBarContent(fileName: "a.md", progress: progress), in: rect, bitmap: idle)
    XCTAssertEqual(fieldFillPixels(idle), 0, "no field by default")
    let counting = try XCTUnwrap(RasterBitmap(width: 900, height: 44))
    bar.draw(
      StatusBarContent(fileName: "a.md", progress: progress, message: StatusMessage("2/14", kind: .find)), in: rect,
      bitmap: counting)
    XCTAssertEqual(fieldFillPixels(counting), 0, "no field while only the matches are active")
    let searching = try XCTUnwrap(RasterBitmap(width: 900, height: 44))
    bar.draw(StatusBarContent(fileName: "a.md", progress: progress, findField: "abc"), in: rect, bitmap: searching)
    XCTAssertGreaterThan(fieldFillPixels(searching), 50)
  }

  func testTheCaretStaysInsideTheFieldAtTheTextHeight() throws {
    let bar = StatusBar(palette: palette, backingScale: 2)
    let rect = CGRect(x: 0, y: 0, width: 900, height: 44)
    let metrics = bar.metrics(in: rect)
    for query in ["", "abc", "Typography"] {
      let bitmap = try XCTUnwrap(RasterBitmap(width: 900, height: 44))
      bar.draw(
        StatusBarContent(fileName: "a.md", progress: ScrollProgress(start: 0, fraction: 1), findField: query),
        in: rect, bitmap: bitmap)
      let geometry = bar.findField(query, right: metrics.hintsX - metrics.gap, in: rect)
      let inside = geometry.field.insetBy(dx: 0, dy: geometry.border)
      XCTAssertGreaterThanOrEqual(geometry.caret.minY, inside.minY + 1, query.debugDescription)
      XCTAssertLessThanOrEqual(geometry.caret.maxY, inside.maxY - 1, query.debugDescription)
      XCTAssertGreaterThan(geometry.caret.height, metrics.fontSize * 0.8, "as tall as a line of text")
      let x = Int(geometry.caret.midX)
      assertColor(bitmap.pixel(x: x, y: Int(geometry.caret.midY)), palette.statusBarText, tolerance: 8, "caret")
      assertColor(
        bitmap.pixel(x: x, y: Int(inside.minY.rounded(.up))), palette.pageBackground, tolerance: 8,
        "the row inside the top border is clear")
      assertColor(
        bitmap.pixel(x: x, y: Int(inside.maxY.rounded(.down)) - 1), palette.pageBackground, tolerance: 8,
        "the row inside the bottom border is clear")
    }
  }
}
