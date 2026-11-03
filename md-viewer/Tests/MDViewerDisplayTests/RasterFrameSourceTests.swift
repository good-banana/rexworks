import CoreGraphics
import MDViewerLayout
import MDViewerRender
import XCTest

@testable import MDViewerCore
@testable import MDViewerDisplay

final class RasterFrameSourceTests: XCTestCase {
  private func makeSource(width: Int) throws -> (RasterFrameSource, PageLayout) {
    let prepared = PreparedDocument(markdown: try fixture("sample"), typography: Typography(backingScale: 2))
    let page = prepared.layout(width: CGFloat(width))
    let status = StatusBarContent(
      fileName: "sample.md", folder: "docs", progress: ScrollProgress(start: 0, fraction: 1),
      message: StatusMessage("3/14", kind: .find))
    return (
      RasterFrameSource(rasterizer: Rasterizer(layout: page, palette: .fallback(dark: true)), status: status), page
    )
  }

  func testPatchesMatchTheFullFramePixelForPixel() throws {
    let size = paneSize(columns: 50, rows: 20, cellWidth: 16, cellHeight: 34)
    let (source, page) = try makeSource(width: 800)
    let viewport = DisplayViewport(size: size, statusRows: 1, pageHeight: page.height, offset: 340)
    let full = try XCTUnwrap(RasterBitmap(width: viewport.frameWidth, height: viewport.frameHeight))
    source.drawFrame(viewport, into: full)
    for rect in [
      PixelRect(x: 0, y: 0, width: 800, height: 40), PixelRect(x: 120, y: 300, width: 200, height: 90),
      PixelRect(x: 0, y: 600, width: 800, height: 80), viewport.statusBarRect,
    ] {
      let patch = try XCTUnwrap(RasterBitmap(width: rect.width, height: rect.height))
      source.drawPatch(rect, viewport: viewport, into: patch)
      var mismatches = 0
      for y in stride(from: 0, to: rect.height, by: 3) {
        for x in stride(from: 0, to: rect.width, by: 3) {
          let expected = full.pixel(x: rect.x + x, y: rect.y + y)
          let actual = patch.pixel(x: x, y: y)
          if let expected, let actual, expected.distance(to: actual) > 2 { mismatches += 1 }
        }
      }
      XCTAssertEqual(mismatches, 0, "patch \(rect)")
    }
  }

  func testStatusBarSitsBelowTheContentAndShowsProgress() throws {
    let size = paneSize(columns: 50, rows: 20, cellWidth: 16, cellHeight: 34)
    let (source, page) = try makeSource(width: 800)
    let viewport = DisplayViewport(size: size, statusRows: 1, pageHeight: page.height)
    let frame = try XCTUnwrap(RasterBitmap(width: viewport.frameWidth, height: viewport.frameHeight))
    source.drawFrame(viewport, into: frame)
    let palette = RenderPalette.fallback(dark: true)
    XCTAssertEqual(frame.pixel(x: 300, y: viewport.contentHeight + 20), palette.statusBarBackground.pixel)
    XCTAssertEqual(frame.pixel(x: 2, y: viewport.contentHeight), palette.progressFill.pixel)
    XCTAssertEqual(frame.pixel(x: 790, y: viewport.contentHeight), palette.progressTrack.pixel)
  }

  func testMissingStatusContentStillFillsTheBar() throws {
    let size = paneSize(columns: 50, rows: 20, cellWidth: 16, cellHeight: 34)
    let (source, page) = try makeSource(width: 800)
    source.status = nil
    let viewport = DisplayViewport(size: size, statusRows: 1, pageHeight: page.height)
    let frame = try XCTUnwrap(RasterBitmap(width: viewport.frameWidth, height: viewport.frameHeight))
    source.drawFrame(viewport, into: frame)
    XCTAssertEqual(
      frame.pixel(x: 400, y: viewport.contentHeight + 5), RenderPalette.fallback(dark: true).statusBarBackground.pixel)
  }

  func testTheEditorPickerIsDrawnOverTheContentAndPatchesMatch() throws {
    let size = paneSize(columns: 50, rows: 20, cellWidth: 16, cellHeight: 34)
    let (source, page) = try makeSource(width: 800)
    let candidates = [EditorCandidate(name: "nvim", executable: "/opt/homebrew/bin/nvim", kind: .neovim)]
    source.editorPicker = EditorPickerContent(candidates: candidates, mode: .here)
    let viewport = DisplayViewport(size: size, statusRows: 1, pageHeight: page.height)
    let full = try XCTUnwrap(RasterBitmap(width: viewport.frameWidth, height: viewport.frameHeight))
    source.drawFrame(viewport, into: full)
    let picker = EditorPicker(content: try XCTUnwrap(source.editorPicker), backingScale: 2)
    let panel = picker.panel(in: viewport.contentRect.cgRect)
    let palette = RenderPalette.fallback(dark: true)
    XCTAssertEqual(full.pixel(x: Int(panel.maxX) - 20, y: Int(panel.maxY) - 12), palette.statusBarBackground.pixel)
    let rect = PixelRect(x: Int(panel.minX) - 10, y: Int(panel.minY) + 20, width: 200, height: 120)
    let patch = try XCTUnwrap(RasterBitmap(width: rect.width, height: rect.height))
    source.drawPatch(rect, viewport: viewport, into: patch)
    for (x, y) in [(4, 4), (60, 50), (190, 110)] {
      XCTAssertEqual(patch.pixel(x: x, y: y), full.pixel(x: rect.x + x, y: rect.y + y))
    }
    source.editorPicker = nil
    let plain = try XCTUnwrap(RasterBitmap(width: viewport.frameWidth, height: viewport.frameHeight))
    source.drawFrame(viewport, into: plain)
    XCTAssertNotEqual(plain.pixel(x: Int(panel.maxX) - 20, y: Int(panel.maxY) - 12), palette.statusBarBackground.pixel)
  }
}
