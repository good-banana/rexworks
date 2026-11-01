import CoreGraphics
import Foundation
import MDViewerDocument
import XCTest

@testable import MDViewerLayout

func fixture(_ name: String) throws -> String {
  let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8)
}

func prepare(_ markdown: String, typography: Typography = Typography()) -> PreparedDocument {
  PreparedDocument(markdown: markdown, typography: typography)
}

func layout(_ markdown: String, width: CGFloat = 1200) -> PageLayout {
  prepare(markdown).layout(width: width)
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

  func center(of needle: String) -> CGPoint? {
    guard let range = range(of: needle), let rect = rects(for: range).first?.rect else { return nil }
    return CGPoint(x: rect.midX, y: rect.midY)
  }

  func fragments(in range: Range<Int>) -> [TextFragment] {
    fragments.filter { $0.range.overlaps(range) }
  }

  func lineTops(for needle: String) -> [CGFloat] {
    guard let range = range(of: needle) else { return [] }
    return Array(Set(fragments(in: range).map(\.lineTop))).sorted()
  }

  func decorations(_ predicate: (DecorationKind) -> Bool) -> [Decoration] {
    decorations.filter { predicate($0.kind) }
  }

  var contentLeft: CGFloat { prepared.typography.pixels(em: prepared.typography.pageMarginSide) }

  var contentWidth: CGFloat { width - contentLeft * 2 }
}

func generatedLargeDocument(lines target: Int) -> String {
  var lines: [String] = ["---", "title: Large fixture", "tags: generated", "---", ""]
  var section = 0
  while lines.count < target {
    section += 1
    lines += [
      "## Section \(section)", "",
      "Paragraph \(section) has **strong text**, *emphasis*, `inline code`, a [link](https://example.com/\(section)) "
        + "and enough words to wrap across several lines at typical pane widths without trouble.",
      "",
      "- item one for \(section)", "- item two with `code`", "  - nested item", "- [x] done task", "",
      "| Column A | Column B | Column C |", "| --- | :---: | ---: |",
      "| a\(section) | centered value | 1,234 |", "| longer cell content here | b | 5 |", "",
      "```swift", "let value\(section) = compute(\(section))", "print(value\(section))", "```", "",
      "> Quoted text for section \(section) with a footnote reference.", "",
    ]
  }
  return lines.joined(separator: "\n")
}
