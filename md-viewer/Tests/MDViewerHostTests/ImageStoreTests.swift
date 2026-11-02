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
    guard started else { return false }
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
