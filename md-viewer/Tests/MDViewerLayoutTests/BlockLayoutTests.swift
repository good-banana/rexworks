import CoreGraphics
import MDViewerDocument
import XCTest

@testable import MDViewerLayout

final class BlockLayoutTests: XCTestCase {
  func testHeadingsScaleAndRuleTheFirstTwoLevels() throws {
    let page = layout("# One\n\n## Two\n\n### Three\n\n###### Six")
    let sizes = try ["One", "Two", "Three", "Six"].map { word -> CGFloat in
      let fragment = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: word))).first)
      return page.prepared.segments[fragment.segment].fontSize
    }
    XCTAssertEqual(sizes, sizes.sorted(by: >))
    XCTAssertEqual(sizes[0], page.prepared.typography.bodyPixelSize * 2, accuracy: 0.01)
    XCTAssertEqual(page.decorations { $0 == .headingRule }.count, 2)
    let six = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "Six"))).first)
    XCTAssertEqual(page.prepared.segments[six.segment].style.color, .muted)
  }

  func testParagraphSpacing() throws {
    let page = layout("First paragraph.\n\nSecond paragraph.")
    let first = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "First"))).first)
    let second = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "Second"))).first)
    XCTAssertEqual(second.lineTop - first.lineBottom, page.prepared.typography.pixels(em: 1), accuracy: 0.01)
  }

  func testListsMarkersNestingAndTasks() throws {
    let page = layout("- one\n- two\n  - nested\n    - deeper\n\n1. first\n2. second\n\n- [x] done\n- [ ] open")
    let markers = page.labels.map { page.prepared.labels[$0.label].text }
    XCTAssertEqual(markers, ["\u{2022}", "\u{2022}", "\u{25E6}", "\u{25AA}", "1.", "2."])
    let one = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "one"))).first)
    let nested = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "nested"))).first)
    XCTAssertEqual(nested.minX - one.minX, page.prepared.typography.pixels(em: 2), accuracy: 0.01)
    let bullet = page.labels[0]
    XCTAssertLessThan(bullet.origin.x, one.minX)
    XCTAssertEqual(bullet.origin.y, one.origin.y, accuracy: 0.01)
    let boxes = page.decorations {
      if case .taskBox = $0 { return true }
      return false
    }
    XCTAssertEqual(boxes.map(\.kind), [.taskBox(checked: true), .taskBox(checked: false)])
    let targets = page.targets.compactMap { area -> Bool? in
      if case .task(_, let checked) = area.target { return checked }
      return nil
    }
    XCTAssertEqual(targets, [true, false])
  }

  func testOrderedListNumberingStylesByDepth() {
    let page = layout("3. a\n4. b\n   1. c\n   2. d\n      1. e")
    XCTAssertEqual(page.labels.map { page.prepared.labels[$0.label].text }, ["3.", "4.", "i.", "ii.", "a."])
  }

  func testTightAndLooseListSpacing() throws {
    let tight = layout("- a\n- b")
    let loose = layout("- a\n\n- b")
    func gap(_ page: PageLayout) throws -> CGFloat {
      let a = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "a"))).first)
      let b = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "b"))).first)
      return b.lineTop - a.lineBottom
    }
    XCTAssertEqual(try gap(tight), tight.prepared.typography.pixels(em: 0.25), accuracy: 0.01)
    XCTAssertEqual(try gap(loose), loose.prepared.typography.pixels(em: 1), accuracy: 0.01)
    XCTAssertEqual(tight.plainText(0..<tight.prepared.text.length), "a\nb")
    XCTAssertEqual(loose.plainText(0..<loose.prepared.text.length), "a\n\nb")
  }

  func testBlockquoteAndAlerts() throws {
    let page = layout("> quoted\n\n> [!WARNING]\n> Careful here.")
    XCTAssertEqual(page.decorations { $0 == .blockquoteBar }.count, 1)
    XCTAssertEqual(page.decorations { $0 == .alertBar(.warning) }.count, 1)
    XCTAssertEqual(page.decorations { $0 == .alertIcon(.warning) }.count, 1)
    let title = try XCTUnwrap(page.labels.first { page.prepared.labels[$0.label].role == .alertTitle(.warning) })
    XCTAssertEqual(page.prepared.labels[title.label].text, "Warning")
    let quoted = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "quoted"))).first)
    XCTAssertEqual(page.prepared.segments[quoted.segment].style.color, .muted)
    let body = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "Careful"))).first)
    XCTAssertGreaterThan(body.lineTop, title.origin.y)
  }

  func testCodeBlockIsMonospacedAndHasCopyTarget() throws {
    let page = layout("```swift\nlet a = 1\n\nlet b = 2\n```")
    XCTAssertEqual(page.decorations { $0 == .codeBlockBackground }.count, 1)
    XCTAssertEqual(page.plainText(0..<page.prepared.text.length), "let a = 1\n\nlet b = 2")
    let code = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "let a"))).first)
    XCTAssertEqual(page.prepared.segments[code.segment].style.color, .code)
    XCTAssertTrue(page.targets.contains { if case .copyCode = $0.target { return true } else { return false } })
    XCTAssertTrue(page.regions.isEmpty)
    XCTAssertEqual(Set(page.fragments.map(\.lineTop)).count, 3)
  }

  func testThematicBreakFrontMatterAndFootnotes() throws {
    let markdown = "---\ntitle: Hello\ntags: a\n---\n\nText with note.[^n]\n\n***\n\nAfter.\n\n[^n]: The note."
    let page = layout(markdown)
    XCTAssertEqual(page.decorations { $0 == .thematicBreak }.count, 1)
    XCTAssertEqual(page.decorations { $0 == .frontMatterBackground }.count, 1)
    XCTAssertEqual(page.decorations { $0 == .frontMatterBar }.count, 1)
    XCTAssertEqual(page.decorations { $0 == .footnoteSeparator }.count, 1)
    let text = page.plainText(0..<page.prepared.text.length)
    XCTAssertTrue(text.hasPrefix("title: Hello\ntags: a\n\nText with note.1"), text)
    XCTAssertTrue(text.hasSuffix("The note. \u{21A9}"), text)
    let box = try XCTUnwrap(page.decorations { $0 == .frontMatterBackground }.first)
    XCTAssertLessThan(box.rect.width, page.contentWidth / 2)
    let reference = try XCTUnwrap(page.range(of: "1", occurrence: 0))
    XCTAssertEqual(page.link(at: reference.lowerBound), "#fn-n")
    let back = try XCTUnwrap(page.range(of: "\u{21A9}"))
    XCTAssertEqual(page.link(at: back.lowerBound), "#fnref-n")
    let definition = try XCTUnwrap(page.anchorPosition("#fn-n"))
    let referenceLine = try XCTUnwrap(page.anchorPosition("fnref-n"))
    XCTAssertGreaterThan(definition.y, referenceLine.y)
    XCTAssertEqual(page.labels.map { page.prepared.labels[$0.label].text }, ["1."])
  }

  func testImagesUseAttributesProviderOrPlaceholderAndFitWidth() throws {
    let markdown = """
      <img src="a.png" width="100" height="50">

      ![b](b.png)

      ![c](c.png)

      <img src="wide.png" width="4000" height="1000">
      """
    let prepared = prepare(markdown)
    let page = prepared.layout(
      LayoutInput(width: 1200, imageSize: { $0 == "b.png" ? CGSize(width: 300, height: 150) : nil }))
    let boxes = Dictionary(uniqueKeysWithValues: page.images.map { ($0.content, $0) })
    let scale = prepared.typography.scale
    XCTAssertEqual(boxes[.image(source: "a.png")]?.rect.size, CGSize(width: 100 * scale, height: 50 * scale))
    XCTAssertEqual(boxes[.image(source: "b.png")]?.rect.size, CGSize(width: 300 * scale, height: 150 * scale))
    XCTAssertEqual(boxes[.image(source: "c.png")]?.hasIntrinsicSize, false)
    let wide = try XCTUnwrap(boxes[.image(source: "wide.png")])
    XCTAssertEqual(wide.rect.width, page.contentWidth, accuracy: 0.01)
    XCTAssertEqual(wide.rect.height, page.contentWidth / 4, accuracy: 0.01)
  }

  func testMermaidIsAnImageLikeBox() throws {
    let markdown = "```mermaid\nflowchart LR\n  A --> B\n```"
    let prepared = prepare(markdown)
    let placeholder = prepared.layout(width: 1200)
    let box = try XCTUnwrap(placeholder.images.first)
    XCTAssertEqual(box.content, .diagram(code: "flowchart LR\n  A --> B\n"))
    XCTAssertFalse(box.hasIntrinsicSize)
    let sized = prepared.layout(LayoutInput(width: 1200, diagramSize: { _ in CGSize(width: 200, height: 100) }))
    let sizedBox = try XCTUnwrap(sized.images.first)
    XCTAssertEqual(sizedBox.rect.size, CGSize(width: 400, height: 200))
    XCTAssertEqual(sizedBox.rect.midX, sized.contentLeft + sized.contentWidth / 2, accuracy: 0.5)
    XCTAssertEqual(sized.markdown(0..<0), markdown)
  }

  func testInlineBoxesForCodeKeyboardAndMark() throws {
    let page = layout("Press <kbd>Ctrl</kbd> and run `make` on <mark>this</mark>, H<sub>2</sub>O and x<sup>2</sup>.")
    XCTAssertEqual(page.decorations { $0 == .inlineBox(.keyboard) }.count, 1)
    XCTAssertEqual(page.decorations { $0 == .inlineBox(.code) }.count, 1)
    XCTAssertEqual(page.decorations { $0 == .inlineBox(.mark) }.count, 1)
    let code = try XCTUnwrap(page.decorations { $0 == .inlineBox(.code) }.first)
    let make = try XCTUnwrap(page.rects(for: XCTUnwrap(page.range(of: "make"))).first)
    XCTAssertLessThan(code.rect.minX, make.rect.minX)
    XCTAssertGreaterThan(code.rect.maxX, make.rect.maxX)
    let sub = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "2"))).first)
    let sup = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "2", occurrence: 1))).first)
    let base = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "Press"))).first)
    XCTAssertGreaterThan(sub.origin.y, base.origin.y)
    XCTAssertLessThan(sup.origin.y, base.origin.y)
  }

  func testInlineStylesShapeOnce() throws {
    let page = layout("**bold** *italic* ~~gone~~ [link](https://x.test) <ins>added</ins> <abbr title=\"t\">ab</abbr>")
    func style(_ word: String) throws -> TextStyle {
      let fragment = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: word))).first)
      return page.prepared.segments[fragment.segment].style
    }
    XCTAssertTrue(try style("gone").decorations.contains(.strikethrough))
    XCTAssertEqual(try style("link").link, "https://x.test")
    XCTAssertEqual(try style("link").color, .link)
    XCTAssertTrue(try style("added").decorations.contains(.underline))
    XCTAssertTrue(try style("ab").decorations.contains(.dottedUnderline))
    let bold = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "bold"))).first)
    let italic = try XCTUnwrap(page.fragments(in: XCTUnwrap(page.range(of: "italic"))).first)
    let boldFont = CTFontCopyTraits(fontOf(page.prepared.segments[bold.segment])) as NSDictionary
    let italicTraits = CTFontGetSymbolicTraits(fontOf(page.prepared.segments[italic.segment]))
    XCTAssertGreaterThan((boldFont[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0, 0.2)
    XCTAssertTrue(italicTraits.contains(.traitItalic))
  }

  func testHTMLTablesListsAndDetails() throws {
    let page = layout(try fixture("readme"))
    XCTAssertFalse(page.decorations { $0 == .tableHeaderFill }.isEmpty)
    XCTAssertTrue(page.targets.contains { if case .detailsToggle = $0.target { return true } else { return false } })
    XCTAssertFalse(page.images.isEmpty)
    XCTAssertNotNil(page.range(of: "Platform"))
    XCTAssertGreaterThan(page.height, 0)
  }

  func testEveryBlockOfTheSampleProducesBoxes() throws {
    let page = layout(try fixture("sample"))
    let kinds = Set(page.decorations.map(\.kind))
    for kind: DecorationKind in [
      .frontMatterBackground, .frontMatterBar, .headingRule, .tableHeaderFill, .tableCellBorder, .codeBlockBackground,
      .alertBar(.warning), .alertIcon(.warning), .taskBox(checked: true), .taskBox(checked: false), .inlineBox(.code),
      .footnoteSeparator, .copyButton,
    ] {
      XCTAssertTrue(kinds.contains(kind), "missing \(kind)")
    }
    XCTAssertEqual(page.images.filter { if case .diagram = $0.content { return true } else { return false } }.count, 1)
    let heading = try XCTUnwrap(page.range(of: "Rollout steps", occurrence: 1))
    XCTAssertEqual(page.anchorPosition("#rollout-steps")?.y, page.fragments(in: heading).first?.lineTop)
  }
}

private func fontOf(_ segment: ShapedSegment) -> CTFont {
  let runs = CTLineGetGlyphRuns(segment.line) as? [CTRun] ?? []
  let attributes = CTRunGetAttributes(runs[0]) as NSDictionary
  return attributes[kCTFontAttributeName] as! CTFont
}
