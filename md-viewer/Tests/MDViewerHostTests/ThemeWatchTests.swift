import Foundation
import XCTest

@testable import MDViewerHost

final class LeaderLockTests: XCTestCase {
  func testOneLeaderAndTakeoverWhenTheLeaderLetsGo() throws {
    let directory = try TestDirectory()
    let url = directory.url.appendingPathComponent("support/theme-watch.lock")
    let first = LeaderLock(url: url)
    let second = LeaderLock(url: url)
    XCTAssertTrue(first.tryAcquire())
    XCTAssertFalse(second.tryAcquire(), "only one viewer leads")
    let tookOver = expectation(description: "takeover")
    second.waitForLeadership(queue: .global()) { tookOver.fulfill() }
    Thread.sleep(forTimeInterval: 0.1)
    XCTAssertFalse(second.isHeld)
    first.release()
    wait(for: [tookOver], timeout: 3)
    XCTAssertTrue(second.isHeld)
    let third = LeaderLock(url: url)
    XCTAssertFalse(third.tryAcquire())
    second.release()
    XCTAssertTrue(third.tryAcquire())
    third.release()
  }

  func testLockFileIsPrivate() throws {
    let directory = try TestDirectory()
    let url = directory.url.appendingPathComponent("theme-watch.lock")
    let lock = LeaderLock(url: url)
    XCTAssertTrue(lock.tryAcquire())
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)
    lock.release()
  }
}

final class ThemeWatchStateTests: XCTestCase {
  func testWatchesOnlyAsLeaderWhileRexRuns() {
    var state = ThemeWatchState(rexRunning: false)
    XCTAssertEqual(state.themeSourceChanged(), [])
    XCTAssertEqual(state.becameLeader(), [], "no watching while Rex is not running")
    XCTAssertEqual(state.rexLaunched(), [.startWatching, .broadcast], "resume with one re-resolve")
    XCTAssertEqual(state.themeSourceChanged(), [.broadcast])
    XCTAssertEqual(state.rexLaunched(), [], "a second launch notice changes nothing")
    XCTAssertEqual(state.rexTerminated(), [.stopWatching])
    XCTAssertEqual(state.themeSourceChanged(), [], "paused")
    XCTAssertEqual(state.rexTerminated(), [])
  }

  func testFollowersNeverWatch() {
    var state = ThemeWatchState(rexRunning: true)
    XCTAssertEqual(state.rexLaunched(), [])
    XCTAssertEqual(state.themeSourceChanged(), [])
    XCTAssertEqual(state.becameLeader(), [.startWatching], "taking over starts watching")
  }
}

@MainActor
final class FileChangeWatcherTests: XCTestCase {
  func testWritesAndAtomicReplacesAreReported() throws {
    let directory = try TestDirectory()
    let file = directory.url.appendingPathComponent("com.superlogical.rex.plist")
    try Data("a".utf8).write(to: file)
    var changes = 0
    let watcher = FileChangeWatcher(file: file) { changes += 1 }
    defer { watcher.stop() }
    try Data("b".utf8).write(to: file)
    spin(until: { changes == 1 })
    XCTAssertEqual(changes, 1)
    let temporary = directory.url.appendingPathComponent("replacement.tmp")
    try Data("c".utf8).write(to: temporary)
    XCTAssertEqual(rename(temporary.path, file.path), 0)
    spin(until: { changes == 2 })
    XCTAssertEqual(changes, 2, "an atomic replace is seen")
    spin(0.3)
    try Data("d".utf8).write(to: file, options: [])
    spin(until: { changes == 3 })
    XCTAssertEqual(changes, 3, "the replaced file is watched again")
  }

  func testAFileCreatedLaterIsWatched() throws {
    let directory = try TestDirectory()
    let file = directory.url.appendingPathComponent("later.plist")
    var changes = 0
    let watcher = FileChangeWatcher(file: file) { changes += 1 }
    defer { watcher.stop() }
    try Data("a".utf8).write(to: file)
    spin(until: { changes == 1 })
    spin(0.3)
    try Data("b".utf8).write(to: file, options: [])
    spin(until: { changes == 2 })
    XCTAssertEqual(changes, 2)
  }

  func testStoppedWatchersStaySilent() throws {
    let directory = try TestDirectory()
    let file = directory.url.appendingPathComponent("x.plist")
    try Data("a".utf8).write(to: file)
    var changes = 0
    let watcher = FileChangeWatcher(file: file) { changes += 1 }
    watcher.stop()
    try Data("b".utf8).write(to: file)
    spin(0.4)
    XCTAssertEqual(changes, 0)
  }
}
