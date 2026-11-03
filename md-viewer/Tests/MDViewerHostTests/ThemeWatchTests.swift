import AppKit
import Foundation
import MDViewerCore
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

  func testOtherFilesInTheDirectoryAreIgnored() throws {
    let directory = try TestDirectory()
    let file = directory.url.appendingPathComponent("com.superlogical.rex.plist")
    try Data("a".utf8).write(to: file)
    var changes = 0
    let watcher = FileChangeWatcher(file: file) { changes += 1 }
    defer { watcher.stop() }
    for index in 0..<5 {
      try Data("x".utf8).write(to: directory.url.appendingPathComponent("com.other.app\(index).plist"))
      try Data("y".utf8).write(to: directory.url.appendingPathComponent("com.other.app\(index).plist"))
    }
    spin(0.5)
    XCTAssertEqual(changes, 0, "unrelated preference files do not count")
    try Data("b".utf8).write(to: file)
    spin(until: { changes == 1 })
    XCTAssertEqual(changes, 1)
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

@MainActor
final class ThemeWatchServiceTests: XCTestCase {
  private final class Flags: @unchecked Sendable {
    var rexRunning = true
  }

  func testLeaderBroadcastsToPeersAndPausesWhileRexIsClosed() throws {
    let home = URL(fileURLWithPath: "/tmp/mdvt-\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = SupportPaths(home: home)
    let preferences = home.appendingPathComponent("Library/Preferences/com.superlogical.rex.plist")
    try FileManager.default.createDirectory(
      at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("1".utf8).write(to: preferences)
    let own = paths.viewerSocket(block: "own")
    let peer = paths.viewerSocket(block: "peer")
    var ownMessages = 0
    var peerMessages = 0
    let ownServer = try ViewerSocketServer(
      socket: own, onOpen: { _ in },
      onTheme: { DispatchQueue.main.async { MainActor.assumeIsolated { ownMessages += 1 } } })
    let peerServer = try ViewerSocketServer(
      socket: peer, onOpen: { _ in },
      onTheme: { DispatchQueue.main.async { MainActor.assumeIsolated { peerMessages += 1 } } })
    defer {
      ownServer.close()
      peerServer.close()
    }
    let flags = Flags()
    let workspace = NotificationCenter()
    let appearance = NotificationCenter()
    let app = NSRunningApplication.current
    let service = ThemeWatchService(
      paths: paths, ownSocket: own, preferencesFile: preferences, isRexRunning: { flags.rexRunning },
      workspaceCenter: workspace, appearanceCenter: appearance, isRexApplication: { $0 === app })
    var local = 0
    service.onLocalChange = { local += 1 }
    service.start()
    defer { service.stop() }
    XCTAssertTrue(service.state.watching)

    try Data("2".utf8).write(to: preferences)
    spin(until: { peerMessages == 1 && local == 1 })
    XCTAssertEqual(peerMessages, 1)
    XCTAssertEqual(local, 1, "the leader re-resolves itself directly")
    spin(0.2)
    XCTAssertEqual(ownMessages, 0, "its own socket is skipped")

    appearance.post(name: ThemeWatchService.appearanceNotification, object: nil)
    spin(until: { peerMessages == 2 })
    XCTAssertEqual(peerMessages, 2)

    flags.rexRunning = false
    workspace.post(
      name: NSWorkspace.didTerminateApplicationNotification, object: nil,
      userInfo: [NSWorkspace.applicationUserInfoKey: app])
    XCTAssertFalse(service.state.watching, "paused while Rex is closed")
    try Data("3".utf8).write(to: preferences)
    appearance.post(name: ThemeWatchService.appearanceNotification, object: nil)
    spin(0.5)
    XCTAssertEqual(peerMessages, 2)

    flags.rexRunning = true
    workspace.post(
      name: NSWorkspace.didLaunchApplicationNotification, object: nil,
      userInfo: [NSWorkspace.applicationUserInfoKey: app])
    XCTAssertTrue(service.state.watching)
    spin(until: { peerMessages == 3 })
    XCTAssertEqual(peerMessages, 3, "relaunch triggers one re-resolve")
    XCTAssertEqual(local, 3)
  }

  func testOnlyTheLeaderWatches() throws {
    let home = try TestDirectory()
    let paths = SupportPaths(home: home.url)
    let first = ThemeWatchService(
      paths: paths, ownSocket: nil, isRexRunning: { true }, workspaceCenter: NotificationCenter(),
      appearanceCenter: NotificationCenter())
    let second = ThemeWatchService(
      paths: paths, ownSocket: nil, isRexRunning: { true }, workspaceCenter: NotificationCenter(),
      appearanceCenter: NotificationCenter())
    first.start()
    second.start()
    XCTAssertTrue(first.state.watching)
    XCTAssertFalse(second.state.watching)
    first.stop()
    spin(until: { second.state.watching })
    XCTAssertTrue(second.state.watching, "the waiting viewer takes over")
    second.stop()
  }

  func testPeerSocketsExcludeTheViewersOwn() throws {
    let directory = try TestDirectory()
    for name in ["a.sock", "b.sock", "notes.txt"] { try Data().write(to: directory.url.appendingPathComponent(name)) }
    let peers = ThemeWatchService.peerSockets(
      in: directory.url, excluding: directory.url.appendingPathComponent("a.sock"))
    XCTAssertEqual(peers.map(\.lastPathComponent), ["b.sock"])
  }

  func testNeovimSocketsAndSidecarsStayOutOfPeerSockets() throws {
    let directory = try TestDirectory()
    let paths = SupportPaths(home: directory.url)
    try FileManager.default.createDirectory(at: paths.viewersDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.neovimSocketsDirectory, withIntermediateDirectories: true)
    try Data().write(to: paths.viewerSocket(block: "block:a"))
    try Data().write(to: paths.neovimControlSocket(id: "abc"))
    try Data().write(to: paths.neovimFiles(id: "abc"))
    XCTAssertFalse(
      paths.neovimSocketsDirectory.standardizedFileURL.path.hasPrefix(
        paths.viewersDirectory.standardizedFileURL.path + "/"))
    let peers = ThemeWatchService.peerSockets(in: paths.viewersDirectory, excluding: nil)
    XCTAssertEqual(peers.map(\.lastPathComponent), [paths.viewerSocket(block: "block:a").lastPathComponent])
  }
}
