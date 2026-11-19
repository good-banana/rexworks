import AppKit
import SideclickCore

private let maxLogBytes: UInt64 = 1_000_000

struct ReturnApp: Sendable {
  let pid: pid_t
  let bundleURL: URL

  @MainActor init?(_ app: NSRunningApplication) {
    guard let bundleURL = app.bundleURL else { return nil }
    pid = app.processIdentifier
    self.bundleURL = bundleURL
  }
}

@MainActor
final class HandlerDelegate: NSObject, NSApplicationDelegate {
  private let paths = SupportPaths(home: FileManager.default.homeDirectoryForCurrentUser)
  private let openQueue = DispatchQueue(label: "sideclick.open")

  func application(_ application: NSApplication, open urls: [URL]) {
    let senderApp = senderApplication()
    let sender = senderApp?.bundleIdentifier
    let optionHeld = NSEvent.modifierFlags.contains(.option)
    let config: Config?
    do {
      config = try ConfigStore.load(paths)
    } catch {
      config = nil
      log("cannot read \(paths.configFile.path): \(error.localizedDescription)")
    }
    let previous = config?.previousHandlers ?? [:]
    for url in urls {
      let destination = route(
        url: url, senderBundleID: sender, optionHeld: optionHeld, previousHandlers: previous,
        isInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
      log(
        "\(url.host ?? "?") from \(sender ?? "unknown") option=\(optionHeld) frontmost=\(frontmost()) -> \(destination)"
      )
      switch destination {
      case .pane:
        guard let config else {
          log("no config; run sideclick setup")
          forward(url, previous: previous)
          continue
        }
        openInPane(url, config: config, returnTo: senderApp.flatMap { ReturnApp($0) })
      case .forward(let bundleID):
        forward(url, to: bundleID)
      }
    }
  }

  private func senderApplication() -> NSRunningApplication? {
    guard
      let pid = NSAppleEventManager.shared().currentAppleEvent?
        .attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
      pid > 0
    else { return nil }
    return NSRunningApplication(processIdentifier: pid)
  }

  private func frontmost() -> String {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
  }

  private func reactivate(_ returnApp: ReturnApp?) {
    guard let returnApp else { return }
    let app = returnApp.bundleURL
    let front = NSWorkspace.shared.frontmostApplication
    let reactivating = shouldReactivate(
      frontmostPID: front?.processIdentifier, ownPID: ProcessInfo.processInfo.processIdentifier,
      senderRunning: NSRunningApplication(processIdentifier: returnApp.pid)?.isTerminated == false)
    log(
      "pane opened; frontmost is \(frontmost()), \(reactivating ? "reactivating" : "leaving") \(app.lastPathComponent)")
    guard reactivating else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
      let message = error.map { "cannot reactivate \(app.lastPathComponent): \($0.localizedDescription)" }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.log(message ?? "reactivated; frontmost is \(self.frontmost())")
        }
      }
    }
  }

  private func openInPane(_ url: URL, config: Config, returnTo app: ReturnApp?) {
    let session = readLastFocusedSession()
    let previous = config.previousHandlers
    let browser = config.browser
    let browserPath = config.browserPath
    let rexPath = config.rexPath
    openQueue.async {
      do {
        let command = try PaneCommand.resolve(browser: browser, browserPath: browserPath)
        _ = try PaneOpener(runner: ProcessRunner(), rexPath: rexPath, command: command)
          .open(url, lastFocusedSession: session)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.reactivate(app) } }
      } catch {
        let message = "cannot open \(url.absoluteString) in \(browser.label): \(error); forwarding"
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            self.log(message)
            self.forward(url, previous: previous)
          }
        }
      }
    }
  }

  private func forward(_ url: URL, previous: [String: String]) {
    let bundleID = forwardTarget(
      scheme: url.scheme ?? "", previousHandlers: previous,
      isInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
    forward(url, to: bundleID)
  }

  private func forward(_ url: URL, to bundleID: String) {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return log("cannot forward \(url.absoluteString): \(bundleID) is not installed")
    }
    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) {
      _, error in
      guard let error else { return }
      let message = "cannot open \(url.absoluteString) with \(bundleID): \(error.localizedDescription)"
      DispatchQueue.main.async { MainActor.assumeIsolated { self.log(message) } }
    }
  }

  private func log(_ message: String) {
    NSLog("sideclick: %@", message)
    let fileManager = FileManager.default
    try? fileManager.createDirectory(
      at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let path = paths.handlerLog.path
    let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
    if !fileManager.fileExists(atPath: path) || size > maxLogBytes {
      fileManager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    guard let handle = try? FileHandle(forWritingTo: paths.handlerLog) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    try? handle.write(contentsOf: Data(line.utf8))
  }
}

MainActor.assumeIsolated {
  let application = NSApplication.shared
  let delegate = HandlerDelegate()
  application.delegate = delegate
  application.setActivationPolicy(.prohibited)
  application.run()
}
