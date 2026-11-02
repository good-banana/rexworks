import CoreGraphics
import XCTest

@testable import MDViewerCore

final class LinkRoutingTests: XCTestCase {
  let current = URL(fileURLWithPath: "/docs/guide/index.md")
  func exists(_ u: URL) -> Bool {
    ["/docs/guide/other.md", "/docs/README.markdown", "/docs/guide/img.png"].contains(u.path)
  }

  func testRelativeMarkdownWithFragment() {
    XCTAssertEqual(
      linkAction(href: "other.md#setup", currentFile: current, fileExists: exists),
      .openMarkdown(URL(fileURLWithPath: "/docs/guide/other.md"), fragment: "setup"))
    XCTAssertEqual(
      linkAction(href: "../README.markdown", currentFile: current, fileExists: exists),
      .openMarkdown(URL(fileURLWithPath: "/docs/README.markdown"), fragment: nil))
  }

  func testAnchorOnly() {
    XCTAssertEqual(linkAction(href: "#install", currentFile: current, fileExists: exists), .scrollToAnchor("install"))
  }

  func testExternalAndLocalNonMarkdown() {
    XCTAssertEqual(
      linkAction(href: "https://example.com", currentFile: current, fileExists: exists),
      .openExternal(URL(string: "https://example.com")!))
    XCTAssertEqual(
      linkAction(href: "mailto:a@b.c", currentFile: current, fileExists: exists),
      .openExternal(URL(string: "mailto:a@b.c")!))
    XCTAssertEqual(
      linkAction(href: "img.png", currentFile: current, fileExists: exists),
      .openExternal(URL(fileURLWithPath: "/docs/guide/img.png")))
  }

  func testIgnoresMissingAndDangerousSchemes() {
    XCTAssertEqual(linkAction(href: "missing.md", currentFile: current, fileExists: exists), .ignore)
    XCTAssertEqual(linkAction(href: "javascript:alert(1)", currentFile: current, fileExists: exists), .ignore)
    XCTAssertEqual(linkAction(href: "ssh://host", currentFile: current, fileExists: exists), .ignore)
  }

  func testPercentEncodedPaths() {
    XCTAssertEqual(
      linkAction(href: "oth%65r.md", currentFile: current, fileExists: exists),
      .openMarkdown(URL(fileURLWithPath: "/docs/guide/other.md"), fragment: nil))
  }

  func testSchemesAreCaseInsensitiveAndWhitespaceTrimmed() {
    XCTAssertEqual(
      linkAction(href: " HTTPS://example.com/a ", currentFile: current, fileExists: exists),
      .openExternal(URL(string: "HTTPS://example.com/a")!))
    XCTAssertEqual(linkAction(href: "JavaScript:alert(1)", currentFile: current, fileExists: exists), .ignore)
    XCTAssertEqual(linkAction(href: "data:text/html,hi", currentFile: current, fileExists: exists), .ignore)
    XCTAssertEqual(linkAction(href: "", currentFile: current, fileExists: exists), .ignore)
    XCTAssertEqual(linkAction(href: "#", currentFile: current, fileExists: exists), .ignore)
  }

  func testFileSchemeAndAbsolutePathsAreLocal() {
    XCTAssertEqual(
      linkAction(href: "file:///docs/guide/other.md#a", currentFile: current, fileExists: exists),
      .openMarkdown(URL(fileURLWithPath: "/docs/guide/other.md"), fragment: "a"))
    XCTAssertEqual(
      linkAction(href: "/docs/guide/img.png?x=1", currentFile: current, fileExists: exists),
      .openExternal(URL(fileURLWithPath: "/docs/guide/img.png")))
  }

  func testPercentEncodedAnchor() {
    XCTAssertEqual(
      linkAction(href: "#caf%C3%A9", currentFile: current, fileExists: exists), .scrollToAnchor("caf\u{e9}"))
  }

  func testLocalFileSafety() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func make(_ name: String, executable: Bool = false) throws -> URL {
      let url = directory.appendingPathComponent(name)
      try Data("x".utf8).write(to: url)
      if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
      return url
    }
    XCTAssertTrue(isSafeToOpenLocally(try make("img.png")))
    XCTAssertTrue(isSafeToOpenLocally(try make("clip.mp4")))
    XCTAssertTrue(isSafeToOpenLocally(try make("notes.txt")))
    XCTAssertTrue(isSafeToOpenLocally(try make("doc.pdf")))
    XCTAssertFalse(isSafeToOpenLocally(try make("run.command")))
    XCTAssertFalse(isSafeToOpenLocally(try make("run.sh")))
    XCTAssertFalse(isSafeToOpenLocally(try make("tool", executable: true)))
    XCTAssertFalse(isSafeToOpenLocally(try make("img2.png", executable: true)))
    XCTAssertFalse(isSafeToOpenLocally(try make("page.webloc")))
    XCTAssertFalse(isSafeToOpenLocally(try make("archive.zip")))
    XCTAssertFalse(isSafeToOpenLocally(try make("image.svg")))
    XCTAssertFalse(isSafeToOpenLocally(try make("page.html")))
    XCTAssertFalse(isSafeToOpenLocally(try make("page.htm")))
    XCTAssertFalse(isSafeToOpenLocally(try make("page.xhtml")))
    XCTAssertFalse(isSafeToOpenLocally(try make("list.m3u8")))
    let app = directory.appendingPathComponent("Evil.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    XCTAssertFalse(isSafeToOpenLocally(app))
    XCTAssertFalse(isSafeToOpenLocally(directory.appendingPathComponent("absent.png")))
  }

  func testSafeLocalImages() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func make(_ name: String) throws -> URL {
      let url = directory.appendingPathComponent(name)
      try Data("x".utf8).write(to: url)
      return url
    }
    XCTAssertTrue(isSafeLocalImage(try make("photo.png")))
    XCTAssertTrue(isSafeLocalImage(try make("photo.jpeg")))
    XCTAssertTrue(isSafeLocalImage(try make("anim.gif")))
    XCTAssertFalse(isSafeLocalImage(try make("vector.svg")))
    XCTAssertFalse(isSafeLocalImage(try make("clip.mp4")))
    XCTAssertFalse(isSafeLocalImage(try make("notes.txt")))
    XCTAssertFalse(isSafeLocalImage(try make("page.html")))
    XCTAssertFalse(isSafeLocalImage(directory.appendingPathComponent("absent.png")))
    let folder = directory.appendingPathComponent("folder.png")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    XCTAssertFalse(isSafeLocalImage(folder))
    let fifo = directory.appendingPathComponent("pipe.png")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    XCTAssertFalse(isSafeLocalImage(fifo))
    let executable = try make("run.png")
    XCTAssertEqual(chmod(executable.path, 0o755), 0)
    XCTAssertFalse(isSafeLocalImage(executable))
  }

  func testPosterCandidates() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func make(_ name: String) throws -> URL {
      let url = directory.appendingPathComponent(name)
      try Data("x".utf8).write(to: url)
      return url
    }
    XCTAssertTrue(isPosterCandidate(try make("clip.mp4")))
    XCTAssertTrue(isPosterCandidate(try make("clip.mov")))
    XCTAssertFalse(isPosterCandidate(try make("live.m3u8")))
    XCTAssertFalse(isPosterCandidate(try make("notes.txt")))
    XCTAssertFalse(isPosterCandidate(try make("img.png")))
    XCTAssertFalse(isPosterCandidate(URL(fileURLWithPath: "/dev/zero")))
    XCTAssertFalse(isPosterCandidate(directory.appendingPathComponent("absent.mp4")))
    let fifo = directory.appendingPathComponent("pipe.mp4")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    XCTAssertFalse(isPosterCandidate(fifo))
  }

  func testCycleWraps() {
    XCTAssertNil(cycle(from: nil, count: 0, forward: true))
    XCTAssertEqual(cycle(from: nil, count: 3, forward: true), 0)
    XCTAssertEqual(cycle(from: nil, count: 3, forward: false), 2)
    XCTAssertEqual(cycle(from: 2, count: 3, forward: true), 0)
    XCTAssertEqual(cycle(from: 0, count: 3, forward: false), 2)
    XCTAssertEqual(cycle(from: 1, count: 3, forward: true), 2)
    XCTAssertEqual(cycle(from: 7, count: 3, forward: true), 0)
  }
}

final class HistoryTests: XCTestCase {
  func testPushPopIsLastInFirstOut() {
    var history = History()
    XCTAssertNil(history.pop())
    let a = History.Entry(file: URL(fileURLWithPath: "/a.md"), offset: 10)
    let b = History.Entry(file: URL(fileURLWithPath: "/b.md"), offset: 20)
    history.push(a)
    history.push(b)
    XCTAssertEqual(history.pop(), b)
    XCTAssertEqual(history.pop(), a)
    XCTAssertNil(history.pop())
  }

  func testDropsOldestBeyondLimit() {
    var history = History(limit: 2)
    for offset in 0..<3 { history.push(.init(file: URL(fileURLWithPath: "/a.md"), offset: CGFloat(offset))) }
    XCTAssertEqual(history.pop()?.offset, 2)
    XCTAssertEqual(history.pop()?.offset, 1)
    XCTAssertNil(history.pop())
  }
}
