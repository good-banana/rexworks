import CoreGraphics
import MDViewerLayout
import XCTest

@testable import MDViewerCore
@testable import MDViewerRender

final class EditorPickerTests: XCTestCase {
  private let palette = RenderPalette.fallback(dark: true)

  private let candidates = [
    EditorCandidate(name: "nvim", executable: "/opt/homebrew/bin/nvim", kind: .neovim),
    EditorCandidate(name: "hx", executable: "/opt/homebrew/bin/hx", kind: .helix),
    EditorCandidate(name: "nano", executable: "/usr/bin/nano", kind: .nano),
    EditorCandidate(name: "code", executable: "/usr/local/bin/code", kind: .vscode),
  ]

  func testRowAndModeText() {
    XCTAssertEqual(EditorPicker.title, "Choose an editor")
    XCTAssertEqual(EditorPicker.rowText(0, candidates[0]), "1  Neovim   /opt/homebrew/bin/nvim   live preview")
    XCTAssertEqual(EditorPicker.rowText(3, candidates[3]), "4  VS Code   opens outside Rex")
    XCTAssertEqual(EditorPicker.rowText(1, candidates[1]), "2  Helix   /opt/homebrew/bin/hx   refreshes on save")
    XCTAssertEqual(
      EditorPicker.modeRow(.split), "Edit with e: beside the preview (Tab to switch to: in this pane)")
    XCTAssertEqual(
      EditorPicker.modeRow(.here), "Edit with e: in this pane (Tab to switch to: beside the preview)")
    XCTAssertEqual(
      EditorPicker.footer,
      "1-9 or arrows and Enter to choose, Tab switches the mode, Esc cancels. Saved to md-viewer's settings.")
    XCTAssertEqual(
      EditorPicker.emptyMessage, "No editor found. Install one, or run md-viewer config set editor <command>")
  }

  func testTheFooterWrapsWithoutLosingWords() {
    let picker = EditorPicker(content: EditorPickerContent(candidates: candidates, mode: .split), backingScale: 2)
    XCTAssertEqual(picker.footerLines(width: 1120), [EditorPicker.footer])
    let lines = picker.footerLines(width: 700)
    XCTAssertEqual(lines.count, 2)
    XCTAssertEqual(lines.joined(separator: " "), EditorPicker.footer)
  }

  func testThePickerFitsAndDrawsAtEveryWidth() throws {
    for width in [160, 420, 900, 1600] {
      let area = CGRect(x: 0, y: 0, width: width, height: 700)
      let content = EditorPickerContent(candidates: candidates, selected: 1, mode: .split)
      let picker = EditorPicker(content: content, backingScale: 2)
      let panel = picker.panel(in: area)
      XCTAssertTrue(area.contains(panel), "the panel fits at \(width) px")
      XCTAssertGreaterThan(panel.width, 0)
      let bitmap = try XCTUnwrap(RasterBitmap(width: width, height: 700))
      bitmap.context.setFillColor(palette.pageBackground.cgColor)
      bitmap.context.fill(CGRect(x: 0, y: 0, width: width, height: 700))
      picker.draw(palette: palette, in: area, clip: area, bitmap: bitmap)
      for index in candidates.indices {
        let row = picker.rowRect(index, in: area)
        XCTAssertTrue(panel.contains(row), "row \(index) is inside the panel at \(width) px")
        XCTAssertEqual(picker.row(at: CGPoint(x: row.midX, y: row.midY), in: area), index)
      }
      let selected = picker.rowRect(1, in: area)
      assertColor(
        bitmap.pixel(x: Int(selected.maxX) - 4, y: Int(selected.midY)), palette.selectionFill, tolerance: 4,
        "the selected row is highlighted at \(width) px")
      let other = picker.rowRect(2, in: area)
      assertColor(
        bitmap.pixel(x: Int(other.maxX) - 4, y: Int(other.midY)), palette.statusBarBackground, tolerance: 4,
        "other rows are not highlighted at \(width) px")
      XCTAssertNil(picker.row(at: CGPoint(x: panel.midX, y: panel.minY + 4), in: area))
    }
  }

  func testRowsBeyondAShortPanelCannotBeChosen() {
    let area = CGRect(x: 0, y: 0, width: 900, height: 150)
    let picker = EditorPicker(content: EditorPickerContent(candidates: candidates, mode: .split), backingScale: 2)
    let panel = picker.panel(in: area)
    XCTAssertTrue(area.contains(panel))
    let last = picker.rowRect(candidates.count - 1, in: area)
    XCTAssertGreaterThan(last.maxY, panel.maxY)
    XCTAssertNil(picker.row(at: CGPoint(x: last.midX, y: last.midY), in: area))
  }

  func testTheEmptyPickerShowsTheMessage() throws {
    let area = CGRect(x: 0, y: 0, width: 1400, height: 700)
    let empty = EditorPicker(content: EditorPickerContent(candidates: [], mode: .split), backingScale: 2)
    let full = EditorPicker(content: EditorPickerContent(candidates: candidates, mode: .split), backingScale: 2)
    XCTAssertLessThan(empty.panel(in: area).height, full.panel(in: area).height)
    XCTAssertEqual(empty.footerLines(width: 1000), [HelpOverlay.footer])
    XCTAssertNil(empty.row(at: CGPoint(x: 700, y: empty.rowRect(0, in: area).midY), in: area))
    let bitmap = try XCTUnwrap(RasterBitmap(width: 1400, height: 700))
    empty.draw(palette: palette, in: area, clip: area, bitmap: bitmap)
    let band = empty.rowRect(0, in: area)
    var inked = 0
    for x in Int(band.minX)..<Int(band.maxX) {
      if let pixel = bitmap.pixel(x: x, y: Int(band.midY)), pixel.distance(to: palette.statusBarBackground.pixel) > 40 {
        inked += 1
      }
    }
    XCTAssertGreaterThan(inked, 20, "the message is drawn")
  }

  func testAPatchMatchesTheFullDraw() throws {
    let picker = EditorPicker(content: EditorPickerContent(candidates: candidates, mode: .here), backingScale: 2)
    let area = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let full = try XCTUnwrap(RasterBitmap(width: 1000, height: 700))
    picker.draw(palette: palette, in: area, clip: area, bitmap: full)
    let patchRect = CGRect(x: 300, y: 200, width: 240, height: 160)
    let patch = try XCTUnwrap(RasterBitmap(width: 240, height: 160))
    picker.draw(palette: palette, in: area, clip: patchRect, origin: patchRect.origin, bitmap: patch)
    for (x, y) in [(10, 10), (120, 80), (230, 150)] {
      XCTAssertEqual(patch.pixel(x: x, y: y), full.pixel(x: 300 + x, y: 200 + y))
    }
  }

  func testTheSourceCursorBarIsPainted() throws {
    let page = prepare("First paragraph\n\nSecond paragraph\n").layout(width: 800)
    let bar = CGRect(x: 14, y: 40, width: 4, height: 30)
    let rasterizer = Rasterizer(layout: page, palette: palette)
    let bitmap = try XCTUnwrap(
      rasterizer.render(
        CGRect(x: 0, y: 0, width: page.width, height: page.height), overlay: RenderOverlay(sourceCursor: bar)))
    assertColor(bitmap.pixel(x: 16, y: 55), palette.focusOutline, "inside the bar")
    assertColor(bitmap.pixel(x: 16, y: 36), palette.pageBackground, "above the bar")
    assertColor(bitmap.pixel(x: 22, y: 55), palette.pageBackground, "beside the bar")
    let plain = try XCTUnwrap(rasterizer.render(CGRect(x: 0, y: 0, width: page.width, height: page.height)))
    assertColor(plain.pixel(x: 16, y: 55), palette.pageBackground, "no bar without a source cursor")
  }
}
