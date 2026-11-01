import AppKit
import MDViewerCore

private let markdownContentType = "net.daringfireball.markdown"
private let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

@MainActor
final class HandlerDelegate: NSObject, NSApplicationDelegate {
  private let paths = SupportPaths(home: FileManager.default.homeDirectoryForCurrentUser)
  private var pending = 0

  func application(_ application: NSApplication, open urls: [URL]) {
    let sender = senderBundleID()
    let config: Config?
    do {
      config = try ConfigStore.load(paths)
    } catch {
      config = nil
      logError("cannot read config: \(error.localizedDescription)")
    }
    let previous = config?.previousHandlers[markdownContentType]
    let destination = route(
      senderBundleID: sender,
      previousHandler: previous,
      handlerExists: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
    for url in urls {
      pending += 1
      handle(url, destination: destination, config: config)
    }
  }

  private func senderBundleID() -> String? {
    guard
      let pid = NSAppleEventManager.shared().currentAppleEvent?
        .attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
      pid > 0
    else { return nil }
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
  }

  private func handle(_ url: URL, destination: OpenRoute, config: Config?) {
    switch destination {
    case .rexPreview:
      guard let config else {
        logError("cannot preview \(url.path): config missing or unreadable at \(paths.configFile.path)")
        return finishOne()
      }
      launchPreview(url, mdViewerPath: config.mdViewerPath)
    case .forward(let bundleID):
      guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        return open(url, with: textEditURL)
      }
      open(url, with: appURL)
    case .textEditFallback:
      open(url, with: textEditURL)
    }
  }

  private func open(_ url: URL, with appURL: URL) {
    NSWorkspace.shared.open(
      [url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()
    ) { _, _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { self.finishOne() } }
    }
  }

  private func launchPreview(_ url: URL, mdViewerPath: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: mdViewerPath)
    process.arguments = ["open", url.path]
    process.standardInput = FileHandle.nullDevice
    let log = openLog()
    process.standardOutput = log
    process.standardError = log
    process.terminationHandler = { _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { self.finishOne() } }
    }
    do {
      try process.run()
    } catch {
      log?.write(Data("cannot launch \(mdViewerPath): \(error.localizedDescription)\n".utf8))
      finishOne()
    }
  }

  private func logError(_ message: String) {
    NSLog("md-viewer handler: %@", message)
    let log = openLog()
    log?.write(Data("\(message)\n".utf8))
    try? log?.close()
  }

  private func openLog() -> FileHandle? {
    let fileManager = FileManager.default
    try? fileManager.createDirectory(
      at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if !fileManager.fileExists(atPath: paths.handlerLog.path) {
      fileManager.createFile(
        atPath: paths.handlerLog.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    guard let handle = try? FileHandle(forWritingTo: paths.handlerLog) else { return nil }
    _ = try? handle.seekToEnd()
    return handle
  }

  private func finishOne() {
    pending -= 1
    if pending <= 0 { NSApplication.shared.terminate(nil) }
  }
}

MainActor.assumeIsolated {
  let application = NSApplication.shared
  let delegate = HandlerDelegate()
  application.delegate = delegate
  application.setActivationPolicy(.prohibited)
  application.run()
}
