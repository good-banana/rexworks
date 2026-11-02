import AppKit
import Darwin
import Foundation
import MDViewerCore

public final class LeaderLock: @unchecked Sendable {
  public let url: URL
  private let lock = NSLock()
  private var descriptor: Int32 = -1
  private var released = false

  public init(url: URL) {
    self.url = url
  }

  deinit { release() }

  public var isHeld: Bool { lock.withLock { descriptor >= 0 } }

  public func tryAcquire() -> Bool {
    guard let candidate = openFile() else { return false }
    guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
      close(candidate)
      return false
    }
    return adopt(candidate)
  }

  public func waitForLeadership(queue: DispatchQueue, onAcquired: @escaping @Sendable () -> Void) {
    let thread = Thread { [weak self] in
      guard let candidate = self?.openFile() else { return }
      while flock(candidate, LOCK_EX) != 0 {
        guard errno == EINTR else {
          close(candidate)
          return
        }
      }
      guard let self else {
        close(candidate)
        return
      }
      guard self.adopt(candidate) else { return }
      queue.async { onAcquired() }
    }
    thread.name = "md-viewer.theme-leader"
    thread.start()
  }

  public func release() {
    lock.withLock {
      released = true
      if descriptor >= 0 { close(descriptor) }
      descriptor = -1
    }
  }

  private func adopt(_ candidate: Int32) -> Bool {
    lock.withLock {
      guard !released, descriptor < 0 else {
        close(candidate)
        return false
      }
      descriptor = candidate
      return true
    }
  }

  private func openFile() -> Int32? {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let candidate = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    return candidate >= 0 ? candidate : nil
  }
}

public struct ThemeWatchState: Equatable, Sendable {
  public enum Action: Equatable, Sendable {
    case startWatching
    case stopWatching
    case broadcast
  }

  public private(set) var isLeader = false
  public private(set) var rexRunning: Bool
  public private(set) var watching = false

  public init(rexRunning: Bool) {
    self.rexRunning = rexRunning
  }

  public mutating func becameLeader() -> [Action] {
    isLeader = true
    return update(broadcast: false)
  }

  public mutating func rexLaunched() -> [Action] {
    rexRunning = true
    return update(broadcast: true)
  }

  public mutating func rexTerminated() -> [Action] {
    rexRunning = false
    return update(broadcast: false)
  }

  public mutating func themeSourceChanged() -> [Action] {
    watching ? [.broadcast] : []
  }

  private mutating func update(broadcast: Bool) -> [Action] {
    let shouldWatch = isLeader && rexRunning
    guard shouldWatch != watching else { return [] }
    watching = shouldWatch
    return shouldWatch ? [.startWatching] + (broadcast ? [.broadcast] : []) : [.stopWatching]
  }
}

@MainActor
public final class FileChangeWatcher {
  public static let debounce: TimeInterval = 0.15

  private let file: URL
  private let onChange: () -> Void
  private var fileSource: DispatchSourceFileSystemObject?
  private var directorySource: DispatchSourceFileSystemObject?
  private var pending = false
  private var stopped = false

  public init(file: URL, onChange: @escaping () -> Void) {
    self.file = file
    self.onChange = onChange
    armDirectory()
    armFile()
  }

  public func stop() {
    stopped = true
    fileSource?.cancel()
    directorySource?.cancel()
    fileSource = nil
    directorySource = nil
  }

  private func armDirectory() {
    let descriptor = open(file.deletingLastPathComponent().path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        if self.fileSource == nil { self.armFile() }
        self.changed()
      }
    }
    source.setCancelHandler { close(descriptor) }
    directorySource = source
    source.resume()
  }

  private func armFile() {
    let descriptor = open(file.path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .rename, .delete], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        if !source.data.isDisjoint(with: [.rename, .delete]) {
          source.cancel()
          self.fileSource = nil
          self.armFile()
        }
        self.changed()
      }
    }
    source.setCancelHandler { close(descriptor) }
    fileSource = source
    source.resume()
  }

  private func changed() {
    guard !pending else { return }
    pending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.pending = false
        if !self.stopped { self.onChange() }
      }
    }
  }
}

@MainActor
public final class ThemeWatchService {
  public static let appearanceNotification = Notification.Name("AppleInterfaceThemeChangedNotification")

  public var onLocalChange: () -> Void = {}
  public private(set) var state: ThemeWatchState
  let lock: LeaderLock
  let preferencesFile: URL
  let viewersDirectory: URL
  let ownSocket: URL?
  let isRexRunning: () -> Bool
  private var preferences: FileChangeWatcher?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private let broadcastQueue = DispatchQueue(label: "md-viewer.theme-broadcast", qos: .utility)

  public init(
    paths: SupportPaths, ownSocket: URL?,
    preferencesFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Preferences/com.superlogical.rex.plist"),
    isRexRunning: @escaping () -> Bool = ThemeWatchService.rexIsRunning
  ) {
    lock = LeaderLock(url: paths.root.appendingPathComponent("theme-watch.lock"))
    self.preferencesFile = preferencesFile
    viewersDirectory = paths.viewersDirectory
    self.ownSocket = ownSocket
    self.isRexRunning = isRexRunning
    state = ThemeWatchState(rexRunning: isRexRunning())
  }

  public nonisolated static func rexIsRunning() -> Bool {
    ThemeResolver.rexBundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
  }

  public func start() {
    observeRexApp()
    if lock.tryAcquire() {
      perform(state.becameLeader())
    } else {
      lock.waitForLeadership(queue: .main) { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.perform(self.state.becameLeader())
        }
      }
    }
  }

  public func stop() {
    preferences?.stop()
    preferences = nil
    for (center, observer) in observers { center.removeObserver(observer) }
    observers = []
    lock.release()
  }

  func perform(_ actions: [ThemeWatchState.Action]) {
    for action in actions {
      switch action {
      case .startWatching: startWatching()
      case .stopWatching: stopWatching()
      case .broadcast: broadcast()
      }
    }
  }

  private func observeRexApp() {
    let center = NSWorkspace.shared.notificationCenter
    for (name, launched) in [
      (NSWorkspace.didLaunchApplicationNotification, true), (NSWorkspace.didTerminateApplicationNotification, false),
    ] {
      let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let bundle = app?.bundleIdentifier, ThemeResolver.rexBundleIDs.contains(bundle) else { return }
        MainActor.assumeIsolated {
          guard let self else { return }
          if launched {
            self.perform(self.state.rexLaunched())
          } else if !self.isRexRunning() {
            self.perform(self.state.rexTerminated())
          }
        }
      }
      observers.append((center, observer))
    }
  }

  private func startWatching() {
    preferences = FileChangeWatcher(file: preferencesFile) { [weak self] in
      guard let self else { return }
      perform(state.themeSourceChanged())
    }
    let center = DistributedNotificationCenter.default()
    let observer = center.addObserver(forName: Self.appearanceNotification, object: nil, queue: .main) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.perform(self.state.themeSourceChanged())
      }
    }
    observers.append((center, observer))
  }

  private func stopWatching() {
    preferences?.stop()
    preferences = nil
    let distributed = DistributedNotificationCenter.default()
    for (center, observer) in observers where center === distributed { center.removeObserver(observer) }
    observers.removeAll { $0.0 === distributed }
  }

  private func broadcast() {
    onLocalChange()
    let directory = viewersDirectory
    let own = ownSocket?.standardizedFileURL.path
    broadcastQueue.async {
      let sockets = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
      for socket in sockets where socket.pathExtension == "sock" && socket.standardizedFileURL.path != own {
        _ = ViewerSocketClient.sendTheme(to: socket)
      }
    }
  }
}
