import Darwin
import Dispatch
import Foundation
import MDViewerCore

struct TerminalSize: Equatable {
  var columns: Int
  var rows: Int
  var pixelWidth: Int
  var pixelHeight: Int
}

nonisolated(unsafe) private var savedAttributes = termios()
nonisolated(unsafe) private var rawModeActive = false
nonisolated(unsafe) private var restoreBytes: [UInt8] = []
nonisolated(unsafe) private var signalSources: [DispatchSourceSignal] = []

private func restoreTerminalState() {
  guard rawModeActive else { return }
  rawModeActive = false
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

  static func size() -> TerminalSize? {
    var ws = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 else {
      return nil
    }
    return TerminalSize(
      columns: Int(ws.ws_col), rows: Int(ws.ws_row),
      pixelWidth: Int(ws.ws_xpixel), pixelHeight: Int(ws.ws_ypixel))
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

  static func queryColors(timeoutMilliseconds: Int = 200) -> (
    foreground: (r: Double, g: Double, b: Double)?, background: (r: Double, g: Double, b: Double)?
  ) {
    let wasRaw = rawModeActive
    var original = termios()
    if !wasRaw {
      guard tcgetattr(STDIN_FILENO, &original) == 0 else { return (nil, nil) }
      var raw = original
      cfmakeraw(&raw)
      guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return (nil, nil) }
    }
    defer {
      if !wasRaw { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
    }

    write("\u{1b}]10;?\u{1b}\\\u{1b}]11;?\u{1b}\\")
    var collected: [UInt8] = []
    var foreground: (r: Double, g: Double, b: Double)?
    var background: (r: Double, g: Double, b: Double)?
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
    while foreground == nil || background == nil {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else { break }
      let remaining = Int32((deadline - now) / 1_000_000) + 1
      collected.append(contentsOf: readAvailable(timeoutMilliseconds: remaining))
      let text = String(decoding: collected, as: UTF8.self)
      for reply in splitReplies(text) {
        if reply.contains("]10;") { foreground = foreground ?? parseColorReply(reply) }
        if reply.contains("]11;") { background = background ?? parseColorReply(reply) }
      }
    }
    return (foreground, background)
  }

  private static func splitReplies(_ text: String) -> [String] {
    var replies: [String] = []
    var current = ""
    for character in text {
      current.append(character)
      if character == "\u{07}" || current.hasSuffix("\u{1b}\\") {
        replies.append(current)
        current = ""
      }
    }
    return replies
  }
}
