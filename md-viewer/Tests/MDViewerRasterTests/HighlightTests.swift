import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout
import XCTest

@testable import MDViewerRender

final class HighlightTests: XCTestCase {
  private func highlight(
    _ code: String, language: String?, using highlighter: SyntaxHighlighter = sharedHighlighter
  ) -> HighlightResult {
    let done = expectation(description: "highlight")
    nonisolated(unsafe) var output: HighlightResult?
    highlighter.highlight(code: code, language: language, queue: DispatchQueue(label: "test")) {
      output = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return output ?? HighlightResult(outcome: .failed)
  }

  private func tokens(_ result: HighlightResult, line: Int, code: String) -> [String: SyntaxToken] {
    let text = code.components(separatedBy: "\n")[line] as NSString
    var map: [String: SyntaxToken] = [:]
    for span in result.tokens(line: line) {
      map[text.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))] = span.token
    }
    return map
  }

  func testScriptIsBundled() {
    XCTAssertNotNil(SyntaxHighlighter.locateScript())
  }

  func testPythonTokens() {
    let code = "import os\n\ndef main(path):\n    # Count entries\n    return len(\"a\") + 42"
    let result = highlight(code, language: "python")
    XCTAssertEqual(result.language, "python")
    XCTAssertEqual(tokens(result, line: 0, code: code)["import"], .keyword)
    XCTAssertEqual(tokens(result, line: 2, code: code)["def"], .keyword)
    XCTAssertEqual(tokens(result, line: 2, code: code)["main"], .function)
    XCTAssertEqual(tokens(result, line: 3, code: code)["# Count entries"], .comment)
    let last = tokens(result, line: 4, code: code)
    XCTAssertEqual(last["\"a\""], .string)
    XCTAssertEqual(last["42"], .number)
    XCTAssertEqual(last["len"], .type)
  }

  func testJSONAndYAMLTokens() {
    let json = "{\n  \"name\": \"md\",\n  \"count\": 3,\n  \"ok\": true\n}"
    let result = highlight(json, language: "json")
    XCTAssertEqual(tokens(result, line: 1, code: json)["\"name\""], .attribute)
    XCTAssertEqual(tokens(result, line: 1, code: json)["\"md\""], .string)
    XCTAssertEqual(tokens(result, line: 2, code: json)["3"], .number)
    XCTAssertEqual(tokens(result, line: 3, code: json)["true"], .keyword)
    let yaml = "worker:\n  size: 200"
    let yamlResult = highlight(yaml, language: "yml")
    XCTAssertEqual(tokens(yamlResult, line: 0, code: yaml)["worker:"], .attribute)
    XCTAssertEqual(tokens(yamlResult, line: 1, code: yaml)["200"], .number)
  }

  func testUTF16RangesAndMultilineTokens() {
    let code = "let s = \"\u{1F600}\u{00E9}\" /* a\nb */ let"
    let result = highlight(code, language: "javascript")
    XCTAssertEqual(tokens(result, line: 0, code: code)["\"\u{1F600}\u{00E9}\""], .string)
    XCTAssertEqual(tokens(result, line: 0, code: code)["/* a"], .comment)
    XCTAssertEqual(tokens(result, line: 1, code: code)["b */"], .comment)
    XCTAssertEqual(tokens(result, line: 1, code: code)["let"], .keyword)
  }

  func testScopeChainResolution() {
    XCTAssertEqual(SyntaxScopes.token(forScopeChain: ["hljs-title function_"]), .function)
    XCTAssertEqual(SyntaxScopes.token(forScopeChain: ["hljs-title class_ inherited__"]), .type)
    XCTAssertEqual(SyntaxScopes.token(forScopeChain: ["hljs-meta", "hljs-keyword"]), .keyword)
    XCTAssertEqual(SyntaxScopes.token(forScopeChain: ["hljs-string", "hljs-unknown"]), .string)
    XCTAssertNil(SyntaxScopes.token(forScopeChain: ["hljs-string", "hljs-subst"]))
    XCTAssertNil(SyntaxScopes.token(forScopeChain: ["hljs-unknown"]))
    XCTAssertEqual(SyntaxScopes.token(forScopeChain: ["hljs-operator"]), .operatorSymbol)
  }

  func testUnknownAndPlainLanguagesStayUnhighlighted() {
    XCTAssertEqual(highlight("x = 1", language: "no-such-language").outcome, .unsupportedLanguage)
    XCTAssertEqual(highlight("x = 1", language: "text").outcome, .unsupportedLanguage)
  }

  func testAutoDetectRespectsRelevanceThreshold() {
    XCTAssertEqual(highlight("just a few plain words here", language: nil).outcome, .belowRelevanceThreshold)
    let code = "#include <stdio.h>\n\nint main(void) {\n  printf(\"hi\\n\");\n  return 0;\n}"
    let detected = highlight(code, language: nil)
    XCTAssertTrue(detected.isHighlighted)
    XCTAssertFalse(detected.lines.allSatisfy(\.isEmpty))
    var strict = SyntaxHighlighter.Configuration()
    strict.autoDetectMinimumRelevance = 10_000
    XCTAssertEqual(
      highlight(code, language: nil, using: SyntaxHighlighter(configuration: strict)).outcome, .belowRelevanceThreshold)
  }

  func testHugeBlocksAreNotHighlighted() {
    var configuration = SyntaxHighlighter.Configuration()
    configuration.maximumInputLength = 1_000
    let highlighter = SyntaxHighlighter(configuration: configuration)
    let code = String(repeating: "let x = 1\n", count: 200)
    let result = highlight(code, language: "swift", using: highlighter)
    XCTAssertEqual(result.outcome, .tooLarge)
    XCTAssertTrue(result.lines.isEmpty)
    XCTAssertTrue(highlight("let x = 1", language: "swift", using: highlighter).isHighlighted)
  }

  func testAsyncCompletionCachesAndCoalesces() {
    let highlighter = SyntaxHighlighter()
    let code = "func f() -> Int { return 1 }"
    XCTAssertNil(highlighter.cached(code: code, language: "swift"))
    let queue = DispatchQueue(label: "callbacks")
    let key = DispatchSpecificKey<Int>()
    queue.setSpecific(key: key, value: 7)
    let first = expectation(description: "first")
    let second = expectation(description: "second")
    let start = DispatchTime.now().uptimeNanoseconds
    highlighter.highlight(code: code, language: "swift", queue: queue) { result in
      XCTAssertEqual(DispatchQueue.getSpecific(key: key), 7)
      XCTAssertTrue(result.isHighlighted)
      first.fulfill()
    }
    highlighter.highlight(code: code, language: "Swift", queue: queue) { _ in second.fulfill() }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    XCTAssertLessThan(elapsed, 5, "requests return without waiting for JavaScriptCore")
    wait(for: [first, second], timeout: 20)
    XCTAssertEqual(highlighter.cached(code: code, language: "swift")?.language, "swift")
    XCTAssertNil(highlighter.cached(code: code + " ", language: "swift"))
  }

  func testDocumentRequestReportsEachBlock() {
    let highlighter = SyntaxHighlighter()
    let prepared = prepare("```swift\nlet a = 1\n```\n\n```json\n{\"a\": 1}\n```\n\n```mermaid\ngraph LR\n```\n")
    let done = expectation(description: "blocks")
    done.expectedFulfillmentCount = 2
    let ready = highlighter.highlight(prepared, queue: DispatchQueue(label: "blocks")) { _, result in
      XCTAssertTrue(result.isHighlighted)
      done.fulfill()
    }
    XCTAssertTrue(ready.isEmpty)
    wait(for: [done], timeout: 20)
    let again = highlighter.highlight(prepared, queue: DispatchQueue(label: "again")) { _, _ in
      XCTFail("cached blocks need no callback")
    }
    XCTAssertEqual(again.count, 2)
  }

  func testRasterizerColorsTokensWithoutMovingGlyphs() throws {
    let code = "def main():\n    return 42"
    let prepared = prepare("```python\n\(code)\n```\n")
    let page = prepared.layout(width: 800)
    let palette = RenderPalette.fallback(dark: true)
    let id = try XCTUnwrap(prepared.codeBlocks.keys.first)
    let result = highlight(try XCTUnwrap(prepared.codeBlocks[id]).code, language: "python")
    let plain = try XCTUnwrap(
      Rasterizer(layout: page, palette: palette).render(CGRect(x: 0, y: 0, width: page.width, height: page.height)))
    let colored = try XCTUnwrap(
      Rasterizer(layout: page, palette: palette, highlights: [id: result]).render(
        CGRect(x: 0, y: 0, width: page.width, height: page.height)))
    let keyword = try XCTUnwrap(page.range(of: "def"))
    let rect = try XCTUnwrap(page.rects(for: keyword).first).rect
    func count(_ bitmap: RasterBitmap, near color: RGB) -> Int {
      var total = 0
      for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) where bitmap.pixel(x: x, y: y)?.distance(to: color.pixel) ?? 99 <= 6 {
          total += 1
        }
      }
      return total
    }
    XCTAssertEqual(count(plain, near: palette.syntax.keyword), 0)
    XCTAssertGreaterThan(count(colored, near: palette.syntax.keyword), 10)
    func coverage(_ bitmap: RasterBitmap) -> Int {
      var total = 0
      for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX)
        where bitmap.pixel(x: x, y: y)?.distance(to: palette.codeBlockBackground.pixel) ?? 0 > 30 {
          total += 1
        }
      }
      return total
    }
    XCTAssertEqual(Double(coverage(plain)), Double(coverage(colored)), accuracy: Double(coverage(plain)) * 0.1)
  }
}
