import Darwin
import Dispatch
import Foundation
import MDViewerCore
import MDViewerSystem

nonisolated(unsafe) private var savedAttributes = termios()
nonisolated(unsafe) private var rawModeActive = false
nonisolated(unsafe) private var restoreBytes: [UInt8] = []
nonisolated(unsafe) private var signalSources: [DispatchSourceSignal] = []

private func restoreTerminalState() {
  guard rawModeActive else { return }
  rawModeActive = false
  mdv_crash_restore_disarm()
  restoreBytes.withUnsafeBufferPointer { buffer in
    _ = Darwin.write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
  }
  tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedAttributes)
}

enum Terminal {
  static func write(_ string: String) {
    let bytes = Array(string.utf8)
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...].withUnsafeBufferPointer {
        Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count)
      }
      if written < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        return
      }
      offset += written
    }
  }

  static func enterRawMode() -> Bool {
    guard !rawModeActive, tcgetattr(STDIN_FILENO, &savedAttributes) == 0 else {
      return rawModeActive
    }
    var raw = savedAttributes
    cfmakeraw(&raw)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return false }
    restoreBytes = Array(TerminalSequences.restore.utf8)
    rawModeActive = true
    atexit { restoreTerminalState() }
    _ = restoreBytes.withUnsafeBufferPointer { bytes in
      bytes.withMemoryRebound(to: CChar.self) {
        mdv_crash_restore_prepare($0.baseAddress, $0.count, STDOUT_FILENO, STDIN_FILENO, &savedAttributes)
      }
    }
    mdv_crash_restore_arm()
    return true
  }

  static func enterViewerMode() -> Bool {
    guard enterRawMode() else { return false }
    write(TerminalSequences.enter)
    return true
  }

  static func restore() {
    restoreTerminalState()
  }

  static func size() -> PaneSize? {
    var ws = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 else {
      return nil
    }
    return PaneSize(
      columns: Int(ws.ws_col), rows: Int(ws.ws_row), pixelWidth: Int(ws.ws_xpixel), pixelHeight: Int(ws.ws_ypixel))
  }

  static func installRestoreHandlers() {
    for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
      source.setEventHandler {
        restoreTerminalState()
        exit(128 + signalNumber)
      }
      source.resume()
      signalSources.append(source)
    }
  }

  static func readAvailable(timeoutMilliseconds: Int32) -> [UInt8] {
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptor, 1, timeoutMilliseconds) > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = read(STDIN_FILENO, &buffer, buffer.count)
    return count > 0 ? Array(buffer[0..<count]) : []
  }

  static func queryColorSet(
    includePalette: Bool = true, includeColorSchemeQuery: Bool = true, timeoutMilliseconds: Int = 200
  ) -> (
    colors: TerminalColorSet, timedOut: Bool
  ) {
    let wasRaw = rawModeActive
    var original = termios()
    if !wasRaw {
      guard tcgetattr(STDIN_FILENO, &original) == 0 else { return (TerminalColorSet(), false) }
      var raw = original
      cfmakeraw(&raw)
      guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return (TerminalColorSet(), false) }
    }
    defer {
      if !wasRaw { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
    }

    write(TerminalColorQuery.request(includePalette: includePalette, includeColorSchemeQuery: includeColorSchemeQuery))
    var reader = TerminalColorReplyReader(expectsPalette: includePalette, expectsColorScheme: includeColorSchemeQuery)
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
    while !reader.isComplete {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else { break }
      let remaining = Int32((deadline - now) / 1_000_000) + 1
      reader.feed(readAvailable(timeoutMilliseconds: remaining))
    }
    return (reader.colors, !reader.isComplete)
  }

  static func themeResolver() -> ThemeResolver {
    let config = try? ConfigStore.load(currentPaths())
    return ThemeResolver(
      runner: ProcessRunner(), preferences: SystemPreferenceReader(), files: SystemThemeFileAccess(),
      rexPath: config?.rexPath ?? locateExecutable("rex"), environment: ProcessInfo.processInfo.environment)
  }

  static func resolveTheme(
    themeSourceBlock: String?, includeColorSchemeQuery: Bool = true, timeoutMilliseconds: Int = 200
  ) -> (theme: ResolvedTheme, queryTimedOut: Bool) {
    let query = queryColorSet(
      includeColorSchemeQuery: includeColorSchemeQuery, timeoutMilliseconds: timeoutMilliseconds)
    return (themeResolver().resolve(inBand: query.colors, sourceBlock: themeSourceBlock), query.timedOut)
  }

  static func crossCheckTheme(
    _ theme: ResolvedTheme, themeSourceBlock: String?, log: @escaping @Sendable (String) -> Void
  ) {
    DispatchQueue.global(qos: .utility).async {
      let resolver = themeResolver()
      if let note = theme.note(for: resolver.crossCheck(theme, sourceBlock: themeSourceBlock)) { log(note) }
    }
  }
}
