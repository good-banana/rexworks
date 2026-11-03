import CoreGraphics
import Foundation
import XCTest

@testable import MDViewerHost

final class ImageLocationTests: XCTestCase {
  private let document = URL(fileURLWithPath: "/docs/guide/readme.md")

  func testRelativeAndAbsolutePathsResolveAgainstTheDocument() {
    XCTAssertEqual(
      ImageLocation(source: "img/a%20b.png?raw=1#x", relativeTo: document),
      .local(URL(fileURLWithPath: "/docs/guide/img/a b.png")))
    XCTAssertEqual(
      ImageLocation(source: "../shared/logo.png", relativeTo: document),
      .local(URL(fileURLWithPath: "/docs/shared/logo.png")))
    XCTAssertEqual(
      ImageLocation(source: "/abs/pic.jpg", relativeTo: document), .local(URL(fileURLWithPath: "/abs/pic.jpg")))
    XCTAssertEqual(
      ImageLocation(source: "file:///abs/pic.jpg", relativeTo: document), .local(URL(fileURLWithPath: "/abs/pic.jpg")))
  }

  func testRemoteSchemesAndRejectedSchemes() {
    XCTAssertEqual(
      ImageLocation(source: "https://example.com/a.png", relativeTo: document),
      .remote(URL(string: "https://example.com/a.png")!))
    XCTAssertEqual(
      ImageLocation(source: "//cdn.example.com/a.png", relativeTo: document),
      .remote(URL(string: "https://cdn.example.com/a.png")!))
    XCTAssertNil(ImageLocation(source: "http://example.com/a.png", relativeTo: document), "https only")
    XCTAssertNil(ImageLocation(source: "data:image/png;base64,AAAA", relativeTo: document))
    XCTAssertNil(ImageLocation(source: "javascript:alert(1)", relativeTo: document))
    XCTAssertNil(ImageLocation(source: "ftp://example.com/a.png", relativeTo: document))
    XCTAssertNil(ImageLocation(source: "http:///nohost.png", relativeTo: document))
    XCTAssertNil(ImageLocation(source: "  ", relativeTo: document))
  }
}

final class ImageStoreTests: XCTestCase {
  func testLocalImagesLoadThroughTheAllowlistAndReportTheirSize() throws {
    let directory = try TestDirectory()
    try pngData(width: 40, height: 20).write(to: directory.url.appendingPathComponent("pic.png"))
    try svgData(width: 30, height: 10).write(to: directory.url.appendingPathComponent("logo.svg"))
    let document = directory.url.appendingPathComponent("doc.md")
    let store = ImageStore()
    XCTAssertTrue(load(store, "pic.png", document))
    XCTAssertEqual(store.sizeProvider(relativeTo: document)("pic.png"), CGSize(width: 40, height: 20))
    XCTAssertNotNil(store.imageProvider(relativeTo: document)("pic.png"))
    XCTAssertTrue(load(store, "logo.svg", document))
    XCTAssertEqual(store.sizeProvider(relativeTo: document)("logo.svg"), CGSize(width: 30, height: 10))
    XCTAssertFalse(load(store, "missing.png", document))
    XCTAssertFalse(
      store.load("pic.png", relativeTo: document) { _ in XCTFail("a known image is not loaded again") })
  }

  func testRemoteImagesUseTheFetcherAndAreCachedForTheSession() {
    let fetches = Counter()
    let data = pngData(width: 8, height: 6)
    let store = ImageStore(fetchRemote: { _, completion in
      fetches.increment()
      completion(data)
    })
    let source = "https://example.com/a.png"
    XCTAssertTrue(load(store, source, nil))
    XCTAssertFalse(store.load(source, relativeTo: URL(fileURLWithPath: "/elsewhere.md")) { _ in })
    XCTAssertEqual(fetches.value, 1)
    XCTAssertEqual(store.sizeProvider(relativeTo: nil)(source), CGSize(width: 8, height: 6))
  }

  func testPosterFramesComeOnlyFromLocalAudiovisualFiles() throws {
    let directory = try TestDirectory()
    try Data("x".utf8).write(to: directory.url.appendingPathComponent("notes.txt"))
    try Data("x".utf8).write(to: directory.url.appendingPathComponent("broken.mp4"))
    let document = directory.url.appendingPathComponent("doc.md")
    let store = ImageStore(fetchRemote: { _, completion in
      XCTFail("remote media is never fetched")
      completion(nil)
    })
    XCTAssertFalse(store.loadPoster("https://example.com/clip.mp4", relativeTo: document) { _ in })
    XCTAssertFalse(poster(store, "notes.txt", document), "not audiovisual")
    XCTAssertFalse(poster(store, "broken.mp4", document), "an unreadable movie gives no frame")
    let generated = ImageStore(posterFrame: { _ in solidImage(width: 32, height: 18) })
    XCTAssertTrue(poster(generated, "any.mov", document))
    XCTAssertEqual(generated.sizeProvider(relativeTo: document)("any.mov"), CGSize(width: 32, height: 18))
  }

  private func poster(_ store: ImageStore, _ source: String, _ document: URL) -> Bool {
    let done = expectation(description: "poster \(source)")
    let result = Flag()
    guard
      store.loadPoster(
        source, relativeTo: document, queue: .global(),
        completion: { available in
          result.set(available)
          done.fulfill()
        })
    else { return false }
    wait(for: [done], timeout: 10)
    return result.value
  }

  func testLargeImagesDecodeToTheDisplaySizeAndTheCacheStaysWithinItsBudget() throws {
    let directory = try TestDirectory()
    let document = directory.url.appendingPathComponent("doc.md")
    for name in ["a", "b", "c"] {
      try pngData(width: 4000, height: 2000).write(to: directory.url.appendingPathComponent("\(name).png"))
    }
    let store = ImageStore(limits: ImageStore.Limits(cacheBytes: 6 << 20))
    store.setDisplayWidth(1200)
    store.pin(["a.png"], relativeTo: document)
    XCTAssertTrue(load(store, "a.png", document))
    let a = try XCTUnwrap(store.image(for: "a.png", relativeTo: document))
    XCTAssertEqual(a.image.width, 1200, "the pane width in device pixels")
    XCTAssertEqual(a.size, CGSize(width: 4000, height: 2000), "layout keeps the intrinsic size")
    XCTAssertTrue(load(store, "b.png", document))
    XCTAssertTrue(load(store, "c.png", document))
    XCTAssertLessThanOrEqual(store.cachedBytes, 6 << 20)
    XCTAssertNotNil(store.image(for: "a.png", relativeTo: document), "pinned sources stay")
    XCTAssertNil(store.image(for: "b.png", relativeTo: document), "the least recently used source went")
    XCTAssertNotNil(store.image(for: "c.png", relativeTo: document))
    XCTAssertTrue(load(store, "b.png", document), "an evicted source loads again")
  }

  func testAnImageCreatedLaterLoadsOnTheNextRequest() throws {
    let directory = try TestDirectory()
    let document = directory.url.appendingPathComponent("doc.md")
    let store = ImageStore()
    XCTAssertFalse(load(store, "late.png", document))
    XCTAssertFalse(store.load("late.png", relativeTo: document) { _ in }, "a still-missing file is not retried")
    try pngData(width: 10, height: 10).write(to: directory.url.appendingPathComponent("late.png"))
    XCTAssertTrue(load(store, "late.png", document))
  }

  func testRemoteFailuresAreRetriedOnlyAfterTheyAreForgotten() {
    let attempts = Counter()
    let data = pngData(width: 4, height: 4)
    let store = ImageStore(fetchRemote: { _, completion in
      attempts.increment()
      completion(attempts.value > 1 ? data : nil)
    })
    let source = "https://example.com/flaky.png"
    XCTAssertFalse(load(store, source, nil))
    XCTAssertFalse(store.load(source, relativeTo: nil) { _ in })
    store.forgetFailures()
    XCTAssertTrue(load(store, source, nil))
    XCTAssertEqual(attempts.value, 2)
  }

  func testAnImageChangedOnDiskIsDecodedAgain() throws {
    let directory = try TestDirectory()
    let document = directory.url.appendingPathComponent("doc.md")
    let file = directory.url.appendingPathComponent("pic.png")
    try pngData(width: 10, height: 10).write(to: file)
    let store = ImageStore()
    XCTAssertTrue(load(store, "pic.png", document))
    XCTAssertFalse(store.load("pic.png", relativeTo: document) { _ in }, "unchanged files are not decoded again")
    try pngData(width: 30, height: 20).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
    XCTAssertEqual(store.sizeProvider(relativeTo: document)("pic.png"), CGSize(width: 10, height: 10))
    XCTAssertTrue(load(store, "pic.png", document))
    XCTAssertEqual(store.sizeProvider(relativeTo: document)("pic.png"), CGSize(width: 30, height: 20))
  }

  func testLargePhotosDecodeAndAreDownscaledToThePane() throws {
    let photo = ImageStore.decode(
      pngData(width: 6000, height: 4000), limits: ImageStore.Limits(maximumBytes: 64 << 20), dimension: 1600)
    let decoded = try XCTUnwrap(photo, "a 24 MP photo still displays")
    XCTAssertEqual(decoded.image.width, 1600)
    XCTAssertEqual(Double(decoded.image.height), 1066.7, accuracy: 1)
    XCTAssertEqual(decoded.size, CGSize(width: 6000, height: 4000))
  }

  func testTallImagesKeepTheirWidthAtThePaneSize() throws {
    let tall = try XCTUnwrap(
      ImageStore.decode(pngData(width: 1200, height: 6000), limits: ImageStore.Limits(), dimension: 1600))
    XCTAssertEqual(tall.image.width, 1200, "narrower than the pane, so not downscaled")
    XCTAssertEqual(tall.image.height, 6000)
  }

  func testDecodeRejectsOversizedInputAndPixelBombs() {
    let data = pngData(width: 64, height: 64)
    XCTAssertNil(ImageStore.decode(data, limits: ImageStore.Limits(maximumBytes: data.count - 1)))
    XCTAssertNil(ImageStore.decode(data, limits: ImageStore.Limits(maximumSourcePixels: 64 * 64 - 1)))
    let bounded = ImageStore.decode(data, limits: ImageStore.Limits(maximumPixels: 32 * 32))
    XCTAssertLessThanOrEqual((bounded?.image.width ?? 0) * (bounded?.image.height ?? 0), 32 * 32)
    XCTAssertNil(ImageStore.decode(Data("not an image".utf8), limits: ImageStore.Limits()))
    let scaled = ImageStore.decode(data, limits: ImageStore.Limits(maximumDimension: 16))
    XCTAssertEqual(scaled?.size, CGSize(width: 64, height: 64), "layout keeps the intrinsic size")
    XCTAssertEqual(scaled?.image.width, 16)
  }

  func testDegenerateAspectRatiosCannotExceedThePixelBudget() throws {
    XCTAssertNil(ImageStore.decode(pngData(width: 1, height: 400), limits: ImageStore.Limits(maximumPixels: 100)))
    let fitted = try XCTUnwrap(
      ImageStore.decode(pngData(width: 10, height: 400), limits: ImageStore.Limits(maximumPixels: 1000)))
    XCTAssertLessThanOrEqual(fitted.image.width * fitted.image.height, 1000)
  }

  func testSVGImagesRasterizeSharplyAtTheirIntrinsicSize() throws {
    let badge = try XCTUnwrap(ImageStore.decode(svgData(width: 100, height: 20), limits: ImageStore.Limits()))
    XCTAssertEqual(badge.size, CGSize(width: 100, height: 20))
    XCTAssertEqual(badge.image.width, 400)
    XCTAssertEqual(badge.image.height, 80)
    let pixel = try XCTUnwrap(rgba(badge.image, x: 200, y: 40))
    XCTAssertEqual(pixel.red, 255, accuracy: 2)
    XCTAssertEqual(pixel.green, 0, accuracy: 2)
    XCTAssertEqual(pixel.alpha, 255, accuracy: 2)
  }

  func testSVGImagesFitThePaneAndThePixelBudget() throws {
    let wide = try XCTUnwrap(
      ImageStore.decode(svgData(width: 2000, height: 100), limits: ImageStore.Limits(), dimension: 1000))
    XCTAssertEqual(wide.size, CGSize(width: 2000, height: 100))
    XCTAssertEqual(wide.image.width, 1000)
    let bounded = try XCTUnwrap(
      ImageStore.decode(svgData(width: 100, height: 100), limits: ImageStore.Limits(maximumPixels: 50 * 50)))
    XCTAssertLessThanOrEqual(bounded.image.width * bounded.image.height, 50 * 50)
  }

  func testDegenerateSVGAspectRatiosCannotExceedThePixelBudget() throws {
    let sliver = try XCTUnwrap(ImageStore.decode(svgData(width: 1, height: 100_000_000), limits: ImageStore.Limits()))
    XCTAssertEqual(sliver.image.width, 1)
    XCTAssertEqual(sliver.image.height, ImageStore.maximumDisplayDimension)
    XCTAssertNil(ImageStore.decode(svgData(width: 1, height: 400), limits: ImageStore.Limits(maximumPixels: 100)))
    let tall = try XCTUnwrap(ImageStore.decode(svgData(width: 100, height: 8000), limits: ImageStore.Limits()))
    XCTAssertEqual(tall.image.height, ImageStore.maximumDisplayDimension)
    XCTAssertEqual(tall.image.width, 51)
  }

  func testNarrowlyRasterizedSVGsAreRasterizedAgainWhenThePaneWidens() throws {
    let directory = try TestDirectory()
    let document = directory.url.appendingPathComponent("doc.md")
    try svgData(width: 200, height: 20).write(to: directory.url.appendingPathComponent("logo.svg"))
    let store = ImageStore()
    store.setDisplayWidth(256)
    XCTAssertTrue(load(store, "logo.svg", document))
    XCTAssertEqual(store.image(for: "logo.svg", relativeTo: document)?.image.width, 256)
    store.setDisplayWidth(1024)
    XCTAssertTrue(load(store, "logo.svg", document))
    XCTAssertEqual(store.image(for: "logo.svg", relativeTo: document)?.image.width, 800)
    store.setDisplayWidth(2048)
    XCTAssertFalse(
      store.load("logo.svg", relativeTo: document) { _ in XCTFail("a full-resolution SVG is not decoded again") })
  }

  func testSVGDecodingRejectsEntityDeclarationsInAnyEncoding() {
    let utf7 = """
      <?xml version="1.0" encoding="UTF-7"?><!DOCTYPE svg [<+ACE-ENTITY a "aaaa">]>
      <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><text>&a;</text></svg>
      """
    XCTAssertNil(ImageStore.decode(Data(utf7.utf8), limits: ImageStore.Limits()))
    let external = """
      <?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a SYSTEM "file:///etc/hosts">]>
      <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><text>&a;</text></svg>
      """
    XCTAssertNil(ImageStore.decode(Data(external.utf8), limits: ImageStore.Limits()))
    let truncated = Data("<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect".utf8)
    XCTAssertNil(ImageStore.decode(truncated, limits: ImageStore.Limits()))
  }

  func testSVGWithADocumentTypeDeclarationStillRendersWithoutLoadingTheDTD() throws {
    let directory = try TestDirectory()
    let dtd = directory.url.appendingPathComponent("entities.dtd")
    try Data(#"<!ENTITY a "aaaa">"#.utf8).write(to: dtd)
    for doctype in [
      #"<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">"#,
      #"<!DOCTYPE svg SYSTEM "\#(dtd.absoluteString)">"#,
    ] {
      let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        \(doctype)
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="10"><rect width="40" height="10" fill="red"/></svg>
        """
      let decoded = ImageStore.decode(Data(svg.utf8), limits: ImageStore.Limits())
      XCTAssertEqual(decoded?.size, CGSize(width: 40, height: 10), doctype)
    }
  }

  func testSVGDecodingRejectsEntitiesAndNonSVGMarkup() {
    let entities = """
      <?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "aaaa">]>
      <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><text>&a;</text></svg>
      """
    XCTAssertNil(ImageStore.decode(Data(entities.utf8), limits: ImageStore.Limits()))
    XCTAssertNil(ImageStore.decode(Data("<html><body>svg</body></html>".utf8), limits: ImageStore.Limits()))
  }

  func testSVGWithoutWidthAndHeightUsesItsViewBox() {
    let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 25"><rect width="50" height="25"/></svg>"#
    XCTAssertEqual(ImageStore.decode(Data(svg.utf8), limits: ImageStore.Limits())?.size, CGSize(width: 50, height: 25))
  }

  func testLightSVGsRenderInProcess() throws {
    let store = ImageStore(
      fetchRemote: { _, completion in completion(Self.svgData(width: 100, height: 20)) },
      renderIsolated: { _, _, _ in
        XCTFail("a light SVG is not sent to a child process")
        return nil
      })
    XCTAssertTrue(load(store, "https://example.com/badge.svg", nil))
    XCTAssertEqual(store.image(for: "https://example.com/badge.svg", relativeTo: nil)?.image.width, 400)
  }

  func testEachHeavyClassOfSVGRendersInAChildProcess() throws {
    let rect = "<rect width='10' height='10' fill='red'/>"
    let blur = "<filter id='b'><feGaussianBlur stdDeviation='200'/></filter>"
    let filtered = "<rect width='1024' height='1024' fill='red' filter='url(#b)'/>"
    let cases = [
      "many elements": canvas(String(repeating: rect, count: 5_000)),
      "amplified by use": canvas(
        "<defs><g id='g'>" + String(repeating: rect, count: 100) + "</g></defs>"
          + String(repeating: "<use xlink:href='#g'/>", count: 100)),
      "many layers": canvas(String(repeating: "<rect width='1024' height='1024' opacity='0.5'/>", count: 17)),
      "many filtered elements": canvas(blur + String(repeating: filtered, count: 9)),
      "filtered through CSS": canvas(
        "<style>rect { filter: url(#b) }</style>" + blur + String(repeating: rect, count: 20)),
      "many filter primitives": canvas(
        "<filter id='b'>" + String(repeating: "<feGaussianBlur stdDeviation='200'/>", count: 17) + "</filter>"
          + filtered),
      "embedded bitmap": canvas(
        "<image width='10' height='10' xlink:href='data:image/png;base64,"
          + pngData(width: 4, height: 4).base64EncodedString() + "'/>"),
      "nested SVG image": canvas(
        "<image width='10' height='10' xlink:href='data:image/svg+xml;base64,"
          + Data(canvas(rect).utf8).base64EncodedString() + "'/>"),
      "huge path": canvas("<path d='M0 0" + String(repeating: " L1 1", count: 220_000) + "' stroke='red'/>"),
      "huge text": canvas("<text y='20'>" + String(repeating: "word ", count: 220_000) + "</text>"),
    ]
    for (label, svg) in cases {
      let isolated = Counter()
      let store = ImageStore(
        fetchRemote: { _, completion in completion(Data(svg.utf8)) },
        renderIsolated: { _, _, _ in
          isolated.increment()
          return LoadedImage(image: solidImage(width: 7, height: 7), size: CGSize(width: 7, height: 7))
        })
      XCTAssertTrue(load(store, "https://example.com/heavy.svg", nil), label)
      XCTAssertEqual(isolated.value, 1, label)
      XCTAssertEqual(store.image(for: "https://example.com/heavy.svg", relativeTo: nil)?.image.width, 7, label)
    }
  }

  func testRejectedSVGsNeverReachAChildProcess() {
    let entities = """
      <?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "aaaa">]>
      <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><text>&a;</text></svg>
      """
    for svg in [entities, "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect"] {
      let store = ImageStore(
        fetchRemote: { _, completion in completion(Data(svg.utf8)) },
        renderIsolated: { _, _, _ in
          XCTFail("a rejected SVG is not rendered")
          return nil
        })
      XCTAssertFalse(load(store, "https://example.com/bad.svg", nil))
    }
  }

  func testAStalledInProcessRenderIsHandedToAChildAndRemembered() throws {
    let slow = Data(slowLightSVG.utf8)
    let isolated = Order()
    let store = ImageStore(
      fetchRemote: { url, completion in
        completion(url.lastPathComponent.hasPrefix("slow") ? slow : Self.svgData(width: 20, height: 10))
      },
      renderIsolated: { data, _, _ in
        isolated.append(data == slow ? "slow" : "fast")
        return LoadedImage(image: solidImage(width: 7, height: 7), size: CGSize(width: 7, height: 7))
      },
      watchdogThreshold: 0.05)
    store.setDisplayWidth(4096)
    XCTAssertTrue(load(store, "https://example.com/slow.svg", nil))
    XCTAssertEqual(store.image(for: "https://example.com/slow.svg", relativeTo: nil)?.image.width, 7)
    XCTAssertTrue(store.isAbandonedRenderRunning)
    XCTAssertTrue(load(store, "https://example.com/fast.svg", nil))
    XCTAssertEqual(isolated.values, ["slow", "fast"], "every SVG goes to a child while a render is abandoned")
    let settled = Date().addingTimeInterval(60)
    while store.isAbandonedRenderRunning, Date() < settled { usleep(10_000) }
    XCTAssertFalse(store.isAbandonedRenderRunning)
    XCTAssertTrue(load(store, "https://example.com/later.svg", nil))
    XCTAssertEqual(store.image(for: "https://example.com/later.svg", relativeTo: nil)?.image.width, 80)
    XCTAssertTrue(load(store, "https://example.com/slow-copy.svg", nil))
    XCTAssertEqual(isolated.values, ["slow", "fast", "slow"], "the stalled document is remembered as heavy")
    XCTAssertFalse(store.isAbandonedRenderRunning)
  }

  func testRasterImagesNeverWaitForSVGRenders() {
    let slow = Data(slowLightSVG.utf8)
    let heavy = Data(canvas(String(repeating: "<rect width='10' height='10'/>", count: 5_000)).utf8)
    let png = pngData(width: 8, height: 8)
    let store = ImageStore(
      fetchRemote: { url, completion in
        switch url.lastPathComponent {
        case "slow.svg": completion(slow)
        case "heavy.svg": completion(heavy)
        default: completion(png)
        }
      },
      renderIsolated: { _, _, _ in
        usleep(1_000_000)
        return LoadedImage(image: solidImage(width: 7, height: 7), size: CGSize(width: 7, height: 7))
      },
      watchdogThreshold: 30)
    store.setDisplayWidth(4096)
    let order = Order()
    let done = expectation(description: "all loaded")
    done.expectedFulfillmentCount = 3
    for source in ["slow.svg", "heavy.svg", "fast.png"].map({ "https://example.com/" + $0 }) {
      XCTAssertTrue(
        store.load(source, relativeTo: nil, queue: .global()) { available in
          XCTAssertTrue(available, source)
          order.append(source)
          done.fulfill()
        })
    }
    wait(for: [done], timeout: 60)
    XCTAssertEqual(order.values.first, "https://example.com/fast.png")
  }

  func testAnEmbeddedGiantBitmapDoesNotGrowTheViewersMemory() throws {
    let bomb = Data(
      canvas(
        "<image width='1024' height='1024' xlink:href='data:image/png;base64,"
          + (try giantPNG(side: 12_000)).base64EncodedString() + "'/>"
      ).utf8)
    let store = ImageStore(
      fetchRemote: { _, completion in completion(bomb) },
      renderIsolated: { SVGRenderProcess(executable: mdViewerExecutable).render($0, limits: $1, dimension: $2) })
    store.setDisplayWidth(4096)
    let before = physicalFootprint()
    XCTAssertFalse(load(store, "https://example.com/bomb.svg", nil, timeout: 10))
    XCTAssertLessThan(physicalFootprint() - before, 64 << 20)
  }

  func testARealBadgeAndAStyledDiagramRenderAtFullResolutionInAChildProcess() throws {
    let isolated = Counter()
    let badgeData = Data(logoBadge.utf8)
    let diagramData = Data(styledDiagram.utf8)
    let store = ImageStore(
      fetchRemote: { url, completion in completion(url.lastPathComponent == "badge.svg" ? badgeData : diagramData) },
      renderIsolated: {
        isolated.increment()
        return SVGRenderProcess(executable: mdViewerExecutable).render($0, limits: $1, dimension: $2)
      })
    store.setDisplayWidth(4096)
    XCTAssertTrue(load(store, "https://example.com/badge.svg", nil, timeout: 10))
    let badge = try XCTUnwrap(store.image(for: "https://example.com/badge.svg", relativeTo: nil))
    XCTAssertEqual(badge.size, CGSize(width: 96, height: 20))
    XCTAssertEqual(badge.image.width, 384)
    XCTAssertEqual(badge.image.height, 80)
    let label = try XCTUnwrap(rgba(badge.image, x: 200, y: 8))
    XCTAssertEqual(label.red, 0x55, accuracy: 24)
    XCTAssertEqual(label.alpha, 255, accuracy: 2)
    XCTAssertTrue(load(store, "https://example.com/diagram.svg", nil, timeout: 10))
    let diagram = try XCTUnwrap(store.image(for: "https://example.com/diagram.svg", relativeTo: nil))
    XCTAssertEqual(diagram.size, CGSize(width: 1600, height: 1000))
    XCTAssertEqual(diagram.image.width, 4096)
    XCTAssertEqual(diagram.image.height, 2560)
    let local = try XCTUnwrap(ImageStore.decodeSVG(diagramData, limits: ImageStore.Limits(), dimension: 4096))
    for (x, y) in [(8, 8), (4 * 185, 4 * 130), (4 * 1000, 4 * 600)] {
      let child = try XCTUnwrap(rgba(diagram.image, x: x, y: y))
      let expected = try XCTUnwrap(rgba(local.image, x: x, y: y))
      XCTAssertEqual(child.red, expected.red, accuracy: 1)
      XCTAssertEqual(child.green, expected.green, accuracy: 1)
      XCTAssertEqual(child.alpha, expected.alpha, accuracy: 1)
    }
    let background = try XCTUnwrap(rgba(diagram.image, x: 8, y: 8))
    let node = try XCTUnwrap(rgba(diagram.image, x: 4 * 185, y: 4 * 130))
    XCTAssertEqual(background.alpha, 255, accuracy: 2)
    XCTAssertLessThan(node.red, background.red - 16, "the node is drawn over the background")
    XCTAssertEqual(isolated.value, 2)
  }

  func testSVGsQueuedBehindAStalledRenderAreHandedToAChild() {
    let slow = Data(slowLightSVG.utf8)
    let isolated = Order()
    let store = ImageStore(
      fetchRemote: { url, completion in
        completion(url.lastPathComponent == "slow.svg" ? slow : Self.svgData(width: 20, height: 10))
      },
      renderIsolated: { data, _, _ in
        isolated.append(data == slow ? "slow" : "queued")
        return LoadedImage(image: solidImage(width: 7, height: 7), size: CGSize(width: 7, height: 7))
      },
      watchdogThreshold: 0.2)
    store.setDisplayWidth(4096)
    let done = expectation(description: "both loaded")
    done.expectedFulfillmentCount = 2
    for source in ["slow.svg", "queued.svg"].map({ "https://example.com/" + $0 }) {
      XCTAssertTrue(store.load(source, relativeTo: nil, queue: .global()) { _ in done.fulfill() })
    }
    wait(for: [done], timeout: 5)
    XCTAssertTrue(store.isAbandonedRenderRunning, "both arrived before the stalled render finished")
    XCTAssertEqual(Set(isolated.values), ["slow", "queued"])
    XCTAssertEqual(store.image(for: "https://example.com/queued.svg", relativeTo: nil)?.image.width, 7)
  }

  private var slowLightSVG: String {
    canvas(
      "<radialGradient id='r'><stop offset='0' stop-color='red'/><stop offset='1' stop-color='blue'/></radialGradient>"
        + String(repeating: "<rect width='1024' height='1024' fill='url(#r)'/>", count: 16))
  }

  func testAShieldsBadgeWithABlurredTextShadowStillRendersAtFullResolution() throws {
    let badge = try XCTUnwrap(ImageStore.decode(Data(shieldsBadge.utf8), limits: ImageStore.Limits()))
    XCTAssertEqual(badge.size, CGSize(width: 106, height: 20))
    XCTAssertEqual(badge.image.width, 424)
    let pixel = try XCTUnwrap(rgba(badge.image, x: 8, y: 40))
    XCTAssertEqual(pixel.red, 0x55, accuracy: 24)
    XCTAssertEqual(pixel.alpha, 255, accuracy: 2)
  }

  private func canvas(_ content: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1024" height="1024">\
    \(content)</svg>
    """
  }

  private let shieldsBadge = """
    <svg xmlns="http://www.w3.org/2000/svg" width="106" height="20" role="img" aria-label="platform: macOS">\
    <title>platform: macOS</title><filter id="blur"><feGaussianBlur stdDeviation="16"/></filter>\
    <linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/>\
    <stop offset="1" stop-opacity=".1"/></linearGradient><clipPath id="r"><rect width="106" height="20" rx="3"/>\
    </clipPath><g clip-path="url(#r)"><rect width="57" height="20" fill="#555"/>\
    <rect x="57" width="49" height="20" fill="#007ec6"/><rect width="106" height="20" fill="url(#s)"/></g>\
    <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" \
    text-rendering="geometricPrecision" font-size="110"><g transform="scale(.1)">\
    <g aria-hidden="true" fill="#010101"><text x="295" y="150" fill-opacity=".8" filter="url(#blur)" \
    textLength="470">platform</text><text x="295" y="150" fill-opacity=".3" textLength="470">platform</text></g>\
    <text x="295" y="140" textLength="470">platform</text></g><g transform="scale(.1)">\
    <g aria-hidden="true" fill="#010101"><text x="805" y="150" fill-opacity=".8" filter="url(#blur)" \
    textLength="390">macOS</text><text x="805" y="150" fill-opacity=".3" textLength="390">macOS</text></g>\
    <text x="805" y="140" textLength="390">macOS</text></g></g></svg>
    """

  private var logoBadge: String {
    let logo = """
      <svg fill="whitesmoke" role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><title>GitHub</title>\
      <path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04\
      -.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 \
      1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466\
      -1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 \
      1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 \
      1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315\
      .21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>
      """
    return """
      <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="96" height="20" \
      role="img" aria-label="github: repo"><title>github: repo</title><linearGradient id="s" x2="0" y2="100%">\
      <stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/></linearGradient>\
      <clipPath id="r"><rect width="96" height="20" rx="3" fill="#fff"/></clipPath><g clip-path="url(#r)">\
      <rect width="61" height="20" fill="#555"/><rect x="61" width="35" height="20" fill="#4c1"/>\
      <rect width="96" height="20" fill="url(#s)"/></g><g fill="#fff" text-anchor="middle" \
      font-family="Verdana,Geneva,DejaVu Sans,sans-serif" text-rendering="geometricPrecision" font-size="110">\
      <image x="5" y="3" width="14" height="14" \
      xlink:href="data:image/svg+xml;base64,\(Data(logo.utf8).base64EncodedString())"/>\
      <text aria-hidden="true" x="395" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" \
      textLength="350">github</text><text x="395" y="140" transform="scale(.1)" fill="#fff" textLength="350">github\
      </text><text aria-hidden="true" x="775" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" \
      textLength="250">repo</text><text x="775" y="140" transform="scale(.1)" fill="#fff" textLength="250">repo</text>\
      </g></svg>
      """
  }

  private var styledDiagram: String {
    var parts = [
      """
      <svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1000" viewBox="0 0 1600 1000"><defs>\
      <filter id="shadow" x="-10%" y="-10%" width="130%" height="140%"><feDropShadow dx="2" dy="3" \
      stdDeviation="4" flood-color="#1a202c" flood-opacity="0.35"/></filter><marker id="arrow" viewBox="0 0 10 10" \
      refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M0 0L10 5L0 10z" fill="#4a5568"/>\
      </marker><linearGradient id="head" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ebf4ff"/>\
      <stop offset="1" stop-color="#c3dafe"/></linearGradient></defs><style>.bg{fill:#f7fafc}\
      .node rect{fill:url(#head);stroke:#5a67d8;stroke-width:1.5}.node{filter:url(#shadow)}\
      .label{font:600 15px -apple-system,Helvetica,sans-serif;fill:#1a202c}.sub{font:12px Menlo,monospace;fill:#4a5568}\
      .edge{fill:none;stroke:#4a5568;stroke-width:1.6;marker-end:url(#arrow)}.edge.dashed{stroke-dasharray:6 4}\
      .lane{fill:none;stroke:#cbd5e0;stroke-dasharray:4 4}</style><rect class="bg" width="1600" height="1000"/>
      """
    ]
    for lane in 0..<4 {
      parts.append(
        "<rect class=\"lane\" x=\"20\" y=\"\(20 + lane * 245)\" width=\"1560\" height=\"230\" rx=\"12\"/>"
          + "<text class=\"sub\" x=\"36\" y=\"\(44 + lane * 245)\">Stage \(lane + 1)</text>")
    }
    let origins = (0..<24).map { (x: 90 + ($0 % 6) * 250, y: 70 + ($0 / 6) * 245) }
    for (index, origin) in origins.enumerated() {
      parts.append(
        "<g class=\"node\" transform=\"translate(\(origin.x),\(origin.y))\"><rect width=\"190\" height=\"120\" "
          + "rx=\"10\"/><text class=\"label\" x=\"95\" y=\"52\" text-anchor=\"middle\">Service \(index)</text>"
          + "<text class=\"sub\" x=\"95\" y=\"78\" text-anchor=\"middle\">port \(8000 + index)</text></g>")
    }
    for (index, (from, to)) in zip(origins, origins.dropFirst()).enumerated() {
      parts.append(
        "<path class=\"edge\(index % 3 == 0 ? " dashed" : "")\" d=\"M\(from.x + 190) \(from.y + 60) "
          + "C\(from.x + 220) \(from.y + 60) \(to.x - 30) \(to.y + 60) \(to.x) \(to.y + 60)\"/>")
    }
    return parts.joined() + "</svg>"
  }

  private static func svgData(width: Int, height: Int) -> Data {
    Data(
      """
      <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)">\
      <rect width="100%" height="100%" fill="#ff0000"/></svg>
      """.utf8)
  }

  private func rgba(_ image: CGImage, x: Int, y: Int) -> (red: Double, green: Double, alpha: Double)? {
    var bytes = [UInt8](repeating: 0, count: 4)
    guard
      let context = CGContext(
        data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (Double(bytes[0]), Double(bytes[1]), Double(bytes[3]))
  }

  private func svgData(width: Int, height: Int) -> Data { Self.svgData(width: width, height: height) }

  private func load(_ store: ImageStore, _ source: String, _ document: URL?, timeout: TimeInterval = 5) -> Bool {
    let done = expectation(description: "loaded \(source)")
    let result = Flag()
    let started = store.load(source, relativeTo: document, queue: .global()) { available in
      result.set(available)
      done.fulfill()
    }
    guard started else {
      done.fulfill()
      return false
    }
    wait(for: [done], timeout: timeout)
    return result.value
  }
}

final class RemoteImageFetcherTests: XCTestCase {
  override func tearDown() {
    StubProtocol.responses = [:]
  }

  func testFetchesSuccessfulResponsesAndRejectsErrorsAndOversizedBodies() {
    StubProtocol.responses = [
      "https://stub.test/ok.png": (200, Data(repeating: 1, count: 100)),
      "https://stub.test/missing.png": (404, Data("nope".utf8)),
      "https://stub.test/huge.png": (200, Data(repeating: 1, count: 5_000)),
    ]
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let fetcher = RemoteImageFetcher(maximumBytes: 1_000, timeout: 5, configuration: configuration)
    defer { fetcher.invalidate() }
    XCTAssertEqual(fetch(fetcher, "https://stub.test/ok.png")?.count, 100)
    XCTAssertNil(fetch(fetcher, "https://stub.test/missing.png"))
    XCTAssertNil(fetch(fetcher, "https://stub.test/huge.png"))
    XCTAssertNil(fetch(fetcher, "file:///etc/hosts"))
    XCTAssertNil(fetch(fetcher, "http://stub.test/ok.png"), "plain http is refused")
  }

  func testRedirectsMustStayOnHTTPSAndAreCapped() {
    StubProtocol.responses = [
      "https://stub.test/ok.png": (200, Data(repeating: 1, count: 10)),
      "https://stub.test/hop.png": (302, Data("https://stub.test/ok.png".utf8)),
      "https://stub.test/downgrade.png": (302, Data("http://stub.test/ok.png".utf8)),
      "https://stub.test/loop.png": (302, Data("https://stub.test/loop.png".utf8)),
    ]
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let fetcher = RemoteImageFetcher(maximumBytes: 1_000, timeout: 5, configuration: configuration)
    defer { fetcher.invalidate() }
    XCTAssertEqual(fetch(fetcher, "https://stub.test/hop.png")?.count, 10)
    XCTAssertNil(fetch(fetcher, "https://stub.test/downgrade.png"))
    XCTAssertNil(fetch(fetcher, "https://stub.test/loop.png"))
  }

  private func fetch(_ fetcher: RemoteImageFetcher, _ url: String) -> Data? {
    let done = expectation(description: url)
    let box = DataBox()
    fetcher.fetch(URL(string: url)!) { data in
      box.set(data)
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return box.value
  }
}

final class StubProtocol: URLProtocol {
  nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let (status, body) = Self.responses[request.url!.absoluteString] ?? (500, Data())
    if (300..<400).contains(status), let target = URL(string: String(decoding: body, as: UTF8.self)) {
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
      client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
      return
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for start in stride(from: 0, to: body.count, by: 512) {
      client?.urlProtocol(self, didLoad: body[start..<min(start + 512, body.count)])
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  var value: Bool { lock.withLock { flag } }
  func set(_ value: Bool) { lock.withLock { flag = value } }
}

final class Order: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  var values: [String] { lock.withLock { items } }
  func append(_ item: String) { lock.withLock { items.append(item) } }
}

final class DataBox: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  var value: Data? { lock.withLock { data } }
  func set(_ value: Data?) { lock.withLock { data = value } }
}
