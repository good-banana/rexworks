import Darwin
import Foundation
import MDViewerCore
import MDViewerSystem
import XCTest

@testable import MDViewerDisplay

final class FrameStagingTests: XCTestCase {
  private var parent: URL!

  override func setUpWithError() throws {
    parent = FileManager.default.temporaryDirectory.appendingPathComponent("mdv-staging-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: parent)
  }

  private func stage(_ stager: FrameStager, _ bytes: [UInt8], at now: UInt64 = 0) throws -> StagedFrame {
    try bytes.withUnsafeBytes { try stager.stage($0, at: now) }
  }

  func testTemporaryFilesAreFreshPrivateAndNamedForTheProtocol() throws {
    let stager = try TemporaryFileStager(parent: parent)
    XCTAssertTrue(stager.directory.lastPathComponent.hasPrefix("tty-graphics-protocol-"))
    let attributes = try FileManager.default.attributesOfItem(atPath: stager.directory.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    let first = try stage(stager, [1, 2, 3, 4])
    let second = try stage(stager, [5, 6, 7, 8])
    guard case .temporaryFile(let path1) = first.medium, case .temporaryFile(let path2) = second.medium else {
      return XCTFail("expected temporary files")
    }
    XCTAssertNotEqual(path1, path2)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path1)), Data([1, 2, 3, 4]))
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: path2)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual(second.sequence, first.sequence + 1)
    XCTAssertEqual(stager.outstanding, 2)
    stager.removeAll()
  }

  func testAcknowledgedFilesAreRemoved() throws {
    let stager = try TemporaryFileStager(parent: parent)
    let first = try stage(stager, [1])
    let second = try stage(stager, [2])
    stager.acknowledge(through: first.sequence)
    guard case .temporaryFile(let path1) = first.medium, case .temporaryFile(let path2) = second.medium else {
      return XCTFail("expected temporary files")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: path1))
    XCTAssertTrue(FileManager.default.fileExists(atPath: path2))
    XCTAssertEqual(stager.outstanding, 1)
    stager.removeAll()
  }

  func testAlreadyConsumedFilesAcknowledgeCleanly() throws {
    let stager = try TemporaryFileStager(parent: parent)
    let frame = try stage(stager, [1])
    if case .temporaryFile(let path) = frame.medium { unlink(path) }
    stager.acknowledge(through: frame.sequence)
    XCTAssertEqual(stager.outstanding, 0)
    stager.removeAll()
  }

  func testStaleFilesAreReclaimed() throws {
    let stager = try TemporaryFileStager(parent: parent)
    _ = try stage(stager, [1], at: 1 * ms)
    _ = try stage(stager, [2], at: 50 * ms)
    stager.reclaim(olderThan: 10 * ms)
    XCTAssertEqual(stager.outstanding, 1)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stager.directory.path), ["2.rgba"])
    stager.removeAll()
  }

  func testLongSessionLeavesNoFiles() throws {
    let stager = try TemporaryFileStager(parent: parent)
    for round in 0..<500 {
      let frame = try stage(stager, [UInt8(round & 0xff)], at: UInt64(round) * ms)
      stager.acknowledge(through: frame.sequence)
    }
    XCTAssertEqual(stager.outstanding, 0)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stager.directory.path), [])
    stager.removeAll()
  }

  func testRemoveAllDeletesTheDirectoryAndUnregistersExitCleanup() throws {
    let stager = try TemporaryFileStager(parent: parent)
    _ = try stage(stager, [1])
    stager.removeAll()
    XCTAssertFalse(FileManager.default.fileExists(atPath: stager.directory.path))
  }

  func testExitCleanupRemovesRegisteredDirectories() throws {
    let stager = try TemporaryFileStager(parent: parent)
    _ = try stage(stager, [1])
    ExitCleanup.shared.run()
    XCTAssertFalse(FileManager.default.fileExists(atPath: stager.directory.path))
    XCTAssertTrue(ExitCleanup.shared.isEmpty)
  }

  func testDeinitRemovesTheDirectory() throws {
    var path = ""
    do {
      let stager = try TemporaryFileStager(parent: parent)
      path = stager.directory.path
      _ = try stage(stager, [1])
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }

  func testAbandonedDirectoriesOfDeadProcessesAreSwept() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try child.run()
    child.waitUntilExit()
    let dead = parent.appendingPathComponent("\(TemporaryFileStager.directoryPrefix)\(child.processIdentifier)")
    let alive = parent.appendingPathComponent("\(TemporaryFileStager.directoryPrefix)1")
    let unrelated = parent.appendingPathComponent("tty-graphics-protocol-other-5")
    for url in [dead, alive, unrelated] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    let stager = try TemporaryFileStager(parent: parent)
    XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: alive.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    stager.removeAll()
  }

  func testSharedMemoryObjectsHoldTheFrameAndAreUnlinked() throws {
    let stager = SharedMemoryStager(prefix: "/mdvt\(getpid())-")
    let frame = try stage(stager, [9, 8, 7, 6])
    guard case .sharedMemory(let name) = frame.medium else { return XCTFail("expected shared memory") }
    XCTAssertLessThanOrEqual(name.utf8.count, 31)
    XCTAssertEqual(try readSharedMemory(name, count: 4), [9, 8, 7, 6])
    stager.acknowledge(through: frame.sequence)
    XCTAssertEqual(stager.outstanding, 0)
    XCTAssertNil(try? readSharedMemory(name, count: 4))
  }

  func testSharedMemoryRemoveAllAndReclaim() throws {
    let stager = SharedMemoryStager(prefix: "/mdvu\(getpid())-")
    let old = try stage(stager, [1], at: 0)
    let recent = try stage(stager, [2], at: 100 * ms)
    stager.reclaim(olderThan: 50 * ms)
    guard case .sharedMemory(let oldName) = old.medium, case .sharedMemory(let recentName) = recent.medium else {
      return XCTFail("expected shared memory")
    }
    XCTAssertNil(try? readSharedMemory(oldName, count: 1))
    XCTAssertEqual(try readSharedMemory(recentName, count: 1), [2])
    stager.removeAll()
    XCTAssertNil(try? readSharedMemory(recentName, count: 1))
    XCTAssertEqual(stager.outstanding, 0)
  }

  private func readSharedMemory(_ name: String, count: Int) throws -> [UInt8] {
    let descriptor = mdv_shm_open_readonly(name)
    guard descriptor >= 0 else { throw StagingError.create(name, errno) }
    defer { close(descriptor) }
    guard let map = mmap(nil, count, PROT_READ, MAP_SHARED, descriptor, 0), map != MAP_FAILED else {
      throw StagingError.write(name, errno)
    }
    defer { munmap(map, count) }
    return Array(UnsafeRawBufferPointer(start: map, count: count))
  }
}

final class PreferredStagingTests: XCTestCase {
  func testSharedMemoryFirstWithTemporaryFilesAsFallback() {
    let stagers = FrameStaging.preferred()
    XCTAssertEqual(stagers.primary.name, "shm")
    XCTAssertEqual(stagers.fallback?.name, "file")
    stagers.fallback?.removeAll()
  }
}
