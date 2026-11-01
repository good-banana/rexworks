import AppKit
import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout
import XCTest

@testable import MDViewerRender

func fixture(_ name: String) throws -> String {
  let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8)
}

func prepare(_ markdown: String, zoom: CGFloat = 1) -> PreparedDocument {
  PreparedDocument(markdown: markdown, typography: Typography(bodySize: 15, zoom: zoom, backingScale: 2))
}

let sharedHighlighter = SyntaxHighlighter()

func highlightAll(_ prepared: PreparedDocument, highlighter: SyntaxHighlighter = sharedHighlighter) -> [BlockID:
  HighlightResult]
{
  let queue = DispatchQueue(label: "test.highlight.results")
  let group = DispatchGroup()
  nonisolated(unsafe) var results: [BlockID: HighlightResult] = [:]
  let blocks = prepared.codeBlocks.filter { !$0.value.isDiagram }
  for (id, block) in blocks {
    group.enter()
    highlighter.highlight(code: block.code, language: block.language, queue: queue) { result in
      results[id] = result
      group.leave()
    }
  }
  group.wait()
  return queue.sync { results }
}

func themePalettes() -> [String: RenderPalette] {
  var data: Data?
  if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.superlogical.rex") {
    data = try? Data(
      contentsOf: app.appendingPathComponent(
        "Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json"))
  }
  if data == nil {
    let fallback = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../MDViewerCoreTests/Fixtures/rex-themes.json").standardizedFileURL
    data = try? Data(contentsOf: fallback)
  }
  var palettes: [String: RenderPalette] = [:]
  for theme in parseRexThemes(data) {
    let colors = TerminalColorSet(
      foreground: theme.foreground, background: theme.background, palette: theme.ansi,
      colorScheme: theme.appearance, cursor: theme.cursor, selectionBackground: theme.selectionBackground)
    palettes[theme.id] = RenderPalette(colors: colors)
  }
  return palettes
}

extension PageLayout {
  func range(of needle: String, occurrence: Int = 0) -> Range<Int>? {
    let text = prepared.text
    var search = NSRange(location: 0, length: text.length)
    var count = 0
    while true {
      let found = text.range(of: needle, options: [], range: search)
      guard found.location != NSNotFound else { return nil }
      if count == occurrence { return found.location..<(found.location + found.length) }
      count += 1
      search = NSRange(location: found.location + found.length, length: text.length - found.location - found.length)
    }
  }

  func decorations(_ predicate: (DecorationKind) -> Bool) -> [Decoration] {
    decorations.filter { predicate($0.kind) }
  }
}

extension RasterBitmap {
  func pixel(_ point: CGPoint) -> PixelColor? { pixel(x: Int(point.x), y: Int(point.y)) }
}

func assertColor(
  _ actual: PixelColor?, _ expected: RGB, tolerance: Int = 3, _ message: String = "", file: StaticString = #filePath,
  line: UInt = #line
) {
  guard let actual else { return XCTFail("no pixel \(message)", file: file, line: line) }
  XCTAssertLessThanOrEqual(
    actual.distance(to: expected.pixel), tolerance, "\(actual) is not \(expected.pixel) \(message)", file: file,
    line: line)
}
