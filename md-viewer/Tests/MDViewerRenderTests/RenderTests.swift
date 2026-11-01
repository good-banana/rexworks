import AVFoundation
import AppKit
import MDViewerCore
import XCTest

@testable import MDViewerWeb

@MainActor
final class RenderTests: XCTestCase {
  func render(_ name: String, dark: Bool = false) async throws -> (WebRenderer, CGFloat) {
    let renderer = try WebRenderer(resources: WebRenderer.resourcesURL())
    let height = try await render(name, with: renderer, dark: dark)
    return (renderer, height)
  }

  func render(_ name: String, with renderer: WebRenderer, dark: Bool = false) async throws -> CGFloat {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures"))
    return try await renderer.render(
      markdown: String(contentsOf: url, encoding: .utf8), fileURL: url, width: 800,
      theme: Theme(dark: dark, background: "#1e1e2e", foreground: "#cdd6f4"))
  }

  func count(_ selector: String, in renderer: WebRenderer) async throws -> Int? {
    try await renderer.evaluate("document.querySelectorAll(\"\(selector)\").length") as? Int
  }

  func testResourcesContainViewer() throws {
    let viewer = try WebRenderer.resourcesURL().appendingPathComponent("viewer.html")
    XCTAssertTrue(FileManager.default.fileExists(atPath: viewer.path))
  }

  func testMissingResourcesThrowInsteadOfCrashing() {
    let missing = URL(fileURLWithPath: "/nonexistent/md-viewer_MDViewerWeb.bundle")
    XCTAssertThrowsError(try WebRenderer.resourcesURL(candidates: [missing])) { error in
      XCTAssertEqual(error as? WebRendererError, .resourcesNotFound(searched: [missing.path]))
    }
  }

  func testConcurrentRendersAreSerialized() async throws {
    let renderer = try WebRenderer(resources: WebRenderer.resourcesURL())
    let first = Task { try await self.render("gfm", with: renderer) }
    let second = Task { try await self.render("links", with: renderer) }
    let firstHeight = try await first.value
    let secondHeight = try await second.value
    XCTAssertGreaterThan(firstHeight, 0)
    XCTAssertGreaterThan(secondHeight, 0)
    let heading = try await renderer.evaluate("document.querySelector('article h1').textContent")
    XCTAssertEqual(heading as? String, "Links")
    let tables = try await count("table", in: renderer)
    XCTAssertEqual(tables, 0)
  }

  func testShortDocumentHeightIgnoresViewport() async throws {
    let (renderer, height) = try await render("short")
    XCTAssertGreaterThan(height, 50)
    XCTAssertLessThan(height, 300)
    _ = try await render("tall", with: renderer)
    let again = try await render("short", with: renderer)
    XCTAssertEqual(again, height)
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
    let lazy = try await count("article [loading]", in: r)
    XCTAssertEqual(lazy, 0)
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

  func testSnapshotCapturesScrolledRegion() async throws {
    let (r, h) = try await render("tall")
    let markerTop = try await r.evaluate(
      "document.getElementById('marker').getBoundingClientRect().top + window.scrollY")
    let top = try XCTUnwrap(markerTop as? Double)
    XCTAssertGreaterThan(top, 600)
    let inside = try await r.snapshot(rect: CGRect(x: 0, y: top - 150, width: 800, height: 300))
    XCTAssertEqual(inside.size, NSSize(width: 800, height: 300))
    XCTAssertFalse(try isMarkerRed(inside, x: 400, y: 50))
    XCTAssertTrue(try isMarkerRed(inside, x: 400, y: 200))
    XCTAssertGreaterThan(top + 400, h)
    let pastEnd = try await r.snapshot(rect: CGRect(x: 0, y: top, width: 800, height: 400))
    XCTAssertTrue(try isMarkerRed(pastEnd, x: 400, y: 100))
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

  func testFocusLinkOutlinesOneLinkAtATime() async throws {
    let (r, _) = try await render("links")
    let links = try await r.links()
    XCTAssertGreaterThan(links.count, 1)
    let focusedHref = "document.querySelector('.md-focus')?.getAttribute('href') ?? null"
    try await r.focusLink(0)
    let first = try await count(".md-focus", in: r)
    XCTAssertEqual(first, 1)
    let firstHref = try await r.evaluate(focusedHref) as? String
    XCTAssertEqual(firstHref, links[0].href)
    try await r.focusLink(1)
    let second = try await count(".md-focus", in: r)
    XCTAssertEqual(second, 1)
    let secondHref = try await r.evaluate(focusedHref) as? String
    XCTAssertEqual(secondHref, links[1].href)
    let after = try await r.links()
    XCTAssertEqual(after, links)
    try await r.focusLink(nil)
    let none = try await count(".md-focus", in: r)
    XCTAssertEqual(none, 0)
  }

  func testMissingPostersListsPlaceholdersWithoutImages() async throws {
    let (r, _) = try await render("links")
    let missing = try await r.missingPosters()
    XCTAssertEqual(missing.map(\.index), [0])
    XCTAssertEqual(missing.map(\.href), ["clip.mp4"])
    let video = try await r.links().first { $0.kind == .video }
    XCTAssertEqual(missing.first?.rect, video?.rect)
    let pixel = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
    let applied = try await r.setPoster(index: 0, dataURL: pixel)
    XCTAssertTrue(applied)
    let absent = try await r.setPoster(index: 5, dataURL: pixel)
    XCTAssertFalse(absent)
    let remaining = try await r.missingPosters()
    XCTAssertEqual(remaining, [])
  }

  func testVideoPosterFromLocalMovie() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let movie = directory.appendingPathComponent("clip.mov")
    try await writeMovie(to: movie)
    let poster = try await VideoPoster.dataURL(for: movie)
    XCTAssertTrue(poster.hasPrefix("data:image/jpeg;base64,"))
    let bytes = try XCTUnwrap(Data(base64Encoded: String(poster.dropFirst("data:image/jpeg;base64,".count))))
    let image = try XCTUnwrap(NSBitmapImageRep(data: bytes))
    XCTAssertEqual(image.pixelsWide, 64)
    do {
      _ = try await VideoPoster.dataURL(for: movie, timeout: .nanoseconds(1))
      XCTFail("expected the poster to time out")
    } catch {
      XCTAssertEqual(error as? WebRendererError, .posterTimedOut)
    }
    let notMovie = directory.appendingPathComponent("notes.mp4")
    try Data("not a movie".utf8).write(to: notMovie)
    do {
      _ = try await VideoPoster.dataURL(for: notMovie)
      XCTFail("expected an error for a file that is not a movie")
    } catch {}
  }

  func writeMovie(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
        kCVPixelBufferHeightKey as String: 64,
      ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<30 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
      let pool = try XCTUnwrap(adaptor.pixelBufferPool)
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
      let pixels = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(pixels, [])
      memset(CVPixelBufferGetBaseAddress(pixels), 0x80, CVPixelBufferGetDataSize(pixels))
      CVPixelBufferUnlockBaseAddress(pixels, [])
      XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
  }

  func isMarkerRed(_ image: NSImage, x: CGFloat, y: CGFloat) throws -> Bool {
    let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    let scale = CGFloat(bitmap.pixelsWide) / image.size.width
    let color = try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
    return color.redComponent > 0.8 && color.greenComponent < 0.3 && color.blueComponent < 0.3
  }
}
