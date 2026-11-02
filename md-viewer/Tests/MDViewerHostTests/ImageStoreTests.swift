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
    try pngData(width: 4, height: 4).write(to: directory.url.appendingPathComponent("disguised.svg"))
    let document = directory.url.appendingPathComponent("doc.md")
    let store = ImageStore()
    XCTAssertTrue(load(store, "pic.png", document))
    XCTAssertEqual(store.sizeProvider(relativeTo: document)("pic.png"), CGSize(width: 40, height: 20))
    XCTAssertNotNil(store.imageProvider(relativeTo: document)("pic.png"))
    XCTAssertFalse(load(store, "disguised.svg", document), "SVG is outside the image allowlist")
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
    store.setDisplayWidth(600)
    store.pin(["a.png"], relativeTo: document)
    XCTAssertTrue(load(store, "a.png", document))
    let a = try XCTUnwrap(store.image(for: "a.png", relativeTo: document))
    XCTAssertEqual(a.image.width, 1200, "twice the pane width")
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

  func testDecodeRejectsOversizedInputAndPixelBombs() {
    let data = pngData(width: 64, height: 64)
    XCTAssertNil(ImageStore.decode(data, limits: ImageStore.Limits(maximumBytes: data.count - 1)))
    XCTAssertNil(ImageStore.decode(data, limits: ImageStore.Limits(maximumPixels: 64 * 64 - 1)))
    XCTAssertNil(ImageStore.decode(Data("not an image".utf8), limits: ImageStore.Limits()))
    let scaled = ImageStore.decode(data, limits: ImageStore.Limits(maximumDimension: 16))
    XCTAssertEqual(scaled?.size, CGSize(width: 64, height: 64), "layout keeps the intrinsic size")
    XCTAssertEqual(scaled?.image.width, 16)
  }

  private func load(_ store: ImageStore, _ source: String, _ document: URL?) -> Bool {
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
    wait(for: [done], timeout: 5)
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
      client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
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

final class DataBox: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  var value: Data? { lock.withLock { data } }
  func set(_ value: Data?) { lock.withLock { data = value } }
}
