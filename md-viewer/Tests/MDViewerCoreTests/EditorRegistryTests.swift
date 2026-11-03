import XCTest

@testable import MDViewerCore

final class EditorRegistryTests: XCTestCase {
  private var home: URL!
  private var paths: SupportPaths!
  private var registry: EditorRegistry!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    paths = SupportPaths(home: home)
    registry = EditorRegistry(paths: paths)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: home)
  }

  private func markdown(_ name: String) throws -> String {
    let url = home.appendingPathComponent(name)
    try Data("# x".utf8).write(to: url)
    return url.path
  }

  private func neovimEntry(block: String, id: String, files: [String] = [], session: String = "session:1")
    throws -> EditorEntry
  {
    try FileManager.default.createDirectory(at: paths.neovimSocketsDirectory, withIntermediateDirectories: true)
    return EditorEntry(
      block: block, mode: .split, session: session, files: files, kind: .neovim,
      controlSocket: paths.neovimControlSocket(id: id).path, preview: "block:preview")
  }

  func testWritesOneFilePerEditorWithPrivateMode() throws {
    let file = try markdown("a.md")
    let entry = EditorEntry(block: "block:e", mode: .split, session: "session:1", files: [file], kind: .helix)
    try registry.write(entry)
    let attributes = try FileManager.default.attributesOfItem(atPath: registry.entryFile(block: "block:e").path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    XCTAssertEqual(registry.entry(block: "block:e"), entry)
    XCTAssertEqual(registry.entries(), [entry])
    try registry.write(
      EditorEntry(block: "block:f", mode: .here, session: "session:1", files: [file], kind: .nano))
    XCTAssertEqual(registry.entries().map(\.block), ["block:e", "block:f"])
  }

  func testLookupCanonicalizesTheFile() throws {
    let file = try markdown("a.md")
    let link = home.appendingPathComponent("link.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: file))
    try registry.write(
      EditorEntry(block: "block:e", mode: .split, session: "session:1", files: [link.path], kind: .helix))
    XCTAssertEqual(registry.entries(listing: file, session: "session:1").map(\.block), ["block:e"])
    XCTAssertEqual(registry.entries(listing: link.path, session: "session:1").map(\.block), ["block:e"])
  }

  func testLookupIsScopedToTheSession() throws {
    let file = try markdown("a.md")
    try registry.write(EditorEntry(block: "block:e", mode: .split, session: "session:1", files: [file], kind: .helix))
    XCTAssertTrue(registry.entries(listing: file, session: "session:2").isEmpty)
  }

  func testHereEntriesAreFound() throws {
    let file = try markdown("a.md")
    try registry.write(
      EditorEntry(block: "block:preview", mode: .here, session: "session:1", files: [file], kind: .nano))
    let found = registry.lookup(file: file, session: "session:1") { _ in .found }
    XCTAssertEqual(found?.mode, .here)
  }

  func testSidecarOnlyFileIsFound() throws {
    let listed = try markdown("a.md")
    let other = try markdown("b.md")
    let entry = try neovimEntry(block: "block:e", id: "n1", files: [listed])
    try registry.write(entry)
    try Data("\(other)\n".utf8).write(to: paths.neovimFiles(id: "n1"))
    XCTAssertEqual(registry.entries(listing: other, session: "session:1").map(\.block), ["block:e"])
    XCTAssertEqual(registry.entries(listing: listed, session: "session:1").map(\.block), ["block:e"])
  }

  func testSidecarLinesAreCanonicalized() throws {
    let entry = try neovimEntry(block: "block:e", id: "n1")
    try registry.write(entry)
    let real = URL(fileURLWithPath: "/private/tmp/md-viewer-registry-\(UUID().uuidString).md")
    try Data("# x".utf8).write(to: real)
    defer { try? FileManager.default.removeItem(at: real) }
    try Data("\(real.path)\n".utf8).write(to: paths.neovimFiles(id: "n1"))
    let tmpPath = "/tmp/" + real.lastPathComponent
    XCTAssertEqual(registry.sidecarFiles(of: entry), [canonicalPath(real.path)])
    XCTAssertEqual(registry.entries(listing: tmpPath, session: "session:1").map(\.block), ["block:e"])
  }

  func testPrunesOnlyOnNotFoundAndRemovesSidecarAndSocket() throws {
    let file = try markdown("a.md")
    let entry = try neovimEntry(block: "block:e", id: "n1", files: [file])
    try registry.write(entry)
    try Data().write(to: paths.neovimControlSocket(id: "n1"))
    try Data("\(file)\n".utf8).write(to: paths.neovimFiles(id: "n1"))

    for kept in [BlockState.found, .unknown] {
      XCTAssertEqual(registry.lookup(file: file, session: "session:1") { _ in kept }, entry)
      XCTAssertEqual(registry.entries(), [entry])
    }

    XCTAssertNil(registry.lookup(file: file, session: "session:1") { _ in .notFound })
    XCTAssertTrue(registry.entries().isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.neovimControlSocket(id: "n1").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.neovimFiles(id: "n1").path))
  }

  func testLookupSkipsAPrunedEntryAndReturnsTheNext() throws {
    let file = try markdown("a.md")
    try registry.write(EditorEntry(block: "block:a", mode: .split, session: "session:1", files: [file], kind: .helix))
    try registry.write(EditorEntry(block: "block:b", mode: .split, session: "session:1", files: [file], kind: .helix))
    let found = registry.lookup(file: file, session: "session:1") { $0 == "block:a" ? .notFound : .found }
    XCTAssertEqual(found?.block, "block:b")
    XCTAssertEqual(registry.entries().map(\.block), ["block:b"])
  }

  func testPruneRemovesOnlyNotFoundBlocks() throws {
    let file = try markdown("a.md")
    for block in ["block:a", "block:b", "block:c"] {
      try registry.write(EditorEntry(block: block, mode: .split, session: "session:1", files: [file], kind: .helix))
    }
    let pruned = registry.prune { block in
      switch block {
      case "block:a": .notFound
      case "block:b": .unknown
      default: .found
      }
    }
    XCTAssertEqual(pruned.map(\.block), ["block:a"])
    XCTAssertEqual(registry.entries().map(\.block), ["block:b", "block:c"])
  }

  func testRemoveDeletesOnlyThatBlock() throws {
    let file = try markdown("a.md")
    let first = try neovimEntry(block: "block:a", id: "n1", files: [file])
    let second = try neovimEntry(block: "block:b", id: "n2", files: [file])
    try registry.write(first)
    try registry.write(second)
    try Data("x".utf8).write(to: paths.neovimFiles(id: "n1"))
    try Data("x".utf8).write(to: paths.neovimFiles(id: "n2"))
    XCTAssertEqual(registry.remove(block: "block:a"), first)
    XCTAssertEqual(registry.entries(), [second])
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.neovimFiles(id: "n1").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.neovimFiles(id: "n2").path))
    XCTAssertNil(registry.remove(block: "block:a"))
  }

  func testFollowGrowsFilesOnceAndCanonically() throws {
    let file = try markdown("a.md")
    let next = try markdown("b.md")
    try registry.write(EditorEntry(block: "block:e", mode: .split, session: "session:1", files: [file], kind: .neovim))
    XCTAssertTrue(try registry.addFile(next, block: "block:e"))
    XCTAssertTrue(try registry.addFile(next, block: "block:e"))
    XCTAssertEqual(registry.entry(block: "block:e")?.files, [canonicalPath(file), canonicalPath(next)])
    XCTAssertFalse(try registry.addFile(next, block: "block:missing"))
    XCTAssertNil(registry.entry(block: "block:missing"))
  }

  func testRelinkChangesPreview() throws {
    let file = try markdown("a.md")
    try registry.write(
      EditorEntry(
        block: "block:e", mode: .split, session: "session:1", files: [file], kind: .neovim, preview: "block:p1"))
    XCTAssertTrue(try registry.setPreview("block:p2", block: "block:e"))
    XCTAssertEqual(registry.entry(block: "block:e")?.preview, "block:p2")
  }

  func testMutationsWorkWhileTheCallerHoldsTheLock() throws {
    let file = try markdown("a.md")
    let lock = try XCTUnwrap(OpenLock.acquire(paths.editLock))
    defer { lock.release() }
    try registry.write(
      EditorEntry(block: "block:e", mode: .split, session: "session:1", files: [file], kind: .neovim), under: lock)
    XCTAssertTrue(try registry.addFile(try markdown("b.md"), block: "block:e", under: lock))
    XCTAssertNotNil(registry.remove(block: "block:e", under: lock))
  }

  func testMutationFailsWhenTheLockCannotBeTaken() throws {
    let holder = try XCTUnwrap(OpenLock.acquire(paths.editLock))
    defer { holder.release() }
    let entry = EditorEntry(block: "block:e", mode: .split, session: "session:1", files: [], kind: .helix)
    let contended = EditorRegistry(paths: paths, lockTimeout: 0.1)
    XCTAssertThrowsError(try contended.write(entry)) {
      XCTAssertEqual($0 as? EditorRegistryError, .lockUnavailable)
    }
  }

  func testUnreadableEntriesAreIgnored() throws {
    try FileManager.default.createDirectory(at: paths.editorsDirectory, withIntermediateDirectories: true)
    try Data("garbage".utf8).write(to: paths.editorsDirectory.appendingPathComponent("bad.json"))
    XCTAssertTrue(registry.entries().isEmpty)
  }
}
