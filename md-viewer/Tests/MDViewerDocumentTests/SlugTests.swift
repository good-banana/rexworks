import MDViewerDocument
import XCTest

final class SlugTests: XCTestCase {
  func slugs(_ markdown: String) -> [String] {
    Document.parse(markdown).headings().compactMap(\.slug)
  }

  func testBasicSlugs() {
    XCTAssertEqual(slugs("# Hello World\n"), ["hello-world"])
    XCTAssertEqual(slugs("# What's new? (v2.0)\n"), ["whats-new-v20"])
    XCTAssertEqual(slugs("# snake_case and kebab-case\n"), ["snake_case-and-kebab-case"])
    XCTAssertEqual(slugs("# Café Ünïcode 日本語\n"), ["café-ünïcode-日本語"])
    XCTAssertEqual(slugs("# a  b\n"), ["a--b"])
    XCTAssertEqual(slugs("# !!!\n"), [""])
    XCTAssertEqual(slugs("# Emoji 🚀 rocket\n"), ["emoji--rocket"])
  }

  func testSlugTextSources() {
    XCTAssertEqual(slugs("# Use `swift build` *now*\n"), ["use-swift-build-now"])
    XCTAssertEqual(slugs("# [Link text](https://x.example) ~~gone~~\n"), ["link-text-gone"])
    XCTAssertEqual(slugs("# Logo ![alt words](logo.png) here\n"), ["logo--here"])
    XCTAssertEqual(slugs("# Press <kbd>Enter</kbd> <span>x</span>\n"), ["press-enter-x"])
    XCTAssertEqual(slugs("Setext *Title*\n===\n"), ["setext-title"])
  }

  func testDedupeLikeGithubSlugger() {
    XCTAssertEqual(slugs("# A\n# A\n# A\n"), ["a", "a-1", "a-2"])
    XCTAssertEqual(slugs("# A\n# A\n# A-1\n"), ["a", "a-1", "a-1-1"])
    XCTAssertEqual(slugs("# A-1\n# A\n# A\n"), ["a-1", "a", "a-2"])
    XCTAssertEqual(slugs("# !!!\n# ???\n"), ["", "-1"])
  }

  func testNestedHeadingsShareTheDedupeScope() {
    XCTAssertEqual(slugs("# Intro\n"), ["intro"])
    let document = Document.parse("# Intro\n\n> # Intro\n\n- # Intro\n")
    XCTAssertEqual(document.blocks[1].quote?.first?.heading?.slug, "intro-1")
    XCTAssertEqual(document.blocks[2].list?.items.first?.blocks.first?.heading?.slug, "intro-2")
  }
}
