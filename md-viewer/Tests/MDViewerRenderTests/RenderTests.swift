import AppKit
import MDViewerCore
import XCTest

@testable import MDViewerWeb

@MainActor
final class RenderTests: XCTestCase {
  func render(_ name: String, dark: Bool = false) async throws -> (WebRenderer, CGFloat) {
    let renderer = WebRenderer(resources: WebRenderer.resourcesURL())
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures"))
    let height = try await renderer.render(
      markdown: String(contentsOf: url, encoding: .utf8), fileURL: url, width: 800,
      theme: Theme(dark: dark, background: "#1e1e2e", foreground: "#cdd6f4"))
    return (renderer, height)
  }

  func count(_ selector: String, in renderer: WebRenderer) async throws -> Int? {
    try await renderer.evaluate("document.querySelectorAll(\"\(selector)\").length") as? Int
  }

  func testResourcesContainViewer() {
    let viewer = WebRenderer.resourcesURL().appendingPathComponent("viewer.html")
    XCTAssertTrue(FileManager.default.fileExists(atPath: viewer.path))
  }

  func testGFMFeatures() async throws {
    let (r, h) = try await render("gfm")
    XCTAssertGreaterThan(h, 100)
    let tables = try await count("table", in: r)
    XCTAssertEqual(tables, 1)
    let checkboxes = try await count("input[type=checkbox]", in: r)
    XCTAssertEqual(checkboxes, 2)
    let checked = try await count("input[type=checkbox][checked][disabled]", in: r)
    XCTAssertEqual(checked, 1)
    let footnotes = try await count(".footnotes li", in: r)
    XCTAssertEqual(footnotes, 1)
    for kind in ["note", "tip", "important", "warning", "caution"] {
      let alerts = try await count(".markdown-alert-\(kind)", in: r)
      XCTAssertEqual(alerts, 1, kind)
    }
    let titles = try await count(".markdown-alert > p.markdown-alert-title", in: r)
    XCTAssertEqual(titles, 5)
    let keywords = try await count("pre code .hljs-keyword", in: r)
    XCTAssertGreaterThan(keywords ?? 0, 0)
    let diagrams = try await count("pre.mermaid svg", in: r)
    XCTAssertEqual(diagrams, 1)
  }

  func testInlineScriptsDoNotRun() async throws {
    let (r, _) = try await render("hostile")
    let untouched = try await r.evaluate("window.__pwned === undefined") as? Bool
    XCTAssertEqual(untouched, true)
    let scripts = try await count("article script", in: r)
    XCTAssertEqual(scripts, 0)
    let handlers = try await r.evaluate(
      "Array.from(document.querySelectorAll('article *')).some(e => e.getAttributeNames().some(n => n.startsWith('on')))"
    )
    XCTAssertEqual(handlers as? Bool, false)
  }

  func testContentSecurityPolicyBlocksInjectedInlineScript() async throws {
    let (r, _) = try await render("hostile")
    let blocked = try await r.evaluate(
      "(() => { const s = document.createElement('script'); s.textContent = 'window.__csp = 1'; document.body.append(s); return window.__csp === undefined })()"
    )
    XCTAssertEqual(blocked as? Bool, true)
  }

  func testLinksAndVideoPlaceholders() async throws {
    let (r, _) = try await render("links")
    let links = try await r.links()
    XCTAssertTrue(links.contains { $0.href.hasSuffix("other.md") && $0.kind == .link && $0.rect.width > 0 })
    XCTAssertTrue(links.contains { $0.href == "https://example.com" && $0.kind == .link })
    XCTAssertTrue(links.contains { $0.href == "clip.mp4" && $0.kind == .video && $0.rect.height > 0 })
    let videos = try await count("article video", in: r)
    XCTAssertEqual(videos, 0)
    let placeholders = try await count(".video-placeholder", in: r)
    XCTAssertEqual(placeholders, 1)
  }

  func testAnchorOffset() async throws {
    let (r, _) = try await render("gfm")
    let heading = try await r.anchorOffset("gfm-fixture")
    XCTAssertNotNil(heading)
    let missing = try await r.anchorOffset("no-such-anchor")
    XCTAssertNil(missing)
  }

  func testSearch() async throws {
    let (r, _) = try await render("gfm")
    let matches = try await r.search("information")
    XCTAssertEqual(matches.count, 3)
    XCTAssertTrue(matches.allSatisfy { $0.width > 0 && $0.height > 0 })
    let none = try await r.search("zzzz-not-present")
    XCTAssertTrue(none.isEmpty)
  }

  func testSnapshotProducesImage() async throws {
    let (r, _) = try await render("gfm", dark: true)
    let image = try await r.snapshot(rect: CGRect(x: 0, y: 0, width: 800, height: 400))
    XCTAssertEqual(image.size.width, 800)
  }

  func testSnapshotBelowTheFoldHasContent() async throws {
    let (r, h) = try await render("gfm", dark: true)
    let image = try await r.snapshot(rect: CGRect(x: 0, y: h - 400, width: 800, height: 400))
    XCTAssertEqual(image.size, NSSize(width: 800, height: 400))
    XCTAssertGreaterThan(try distinctColors(in: image), 1)
  }

  func testThemeDoesNotChangeLayoutHeight() async throws {
    let (_, dark) = try await render("gfm", dark: true)
    let (_, light) = try await render("gfm", dark: false)
    XCTAssertEqual(dark, light)
  }

  func testSetPosterShowsImage() async throws {
    let (r, _) = try await render("links")
    let pixel = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
    try await r.setPoster(index: 0, dataURL: pixel)
    let source = try await r.evaluate(
      "document.querySelector('.video-placeholder img.video-poster').getAttribute('src')")
    XCTAssertEqual(source as? String, pixel)
  }

  func distinctColors(in image: NSImage) throws -> Int {
    let data = try XCTUnwrap(image.tiffRepresentation)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
    var colors = Set<String>()
    for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
      for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
        if let color = bitmap.colorAt(x: x, y: y) { colors.insert(color.description) }
      }
    }
    return colors.count
  }
}
