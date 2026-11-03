import Darwin
import Foundation

public let maxOpenMessageBytes = 4096

public func validateOpenMessage(_ line: String, fileExists: (String) -> Bool) -> URL? {
  let path = line.trimmingCharacters(in: .newlines)
  guard path.utf8.count < maxOpenMessageBytes, path.hasPrefix("/"),
    !path.unicodeScalars.contains("\u{0}"),
    ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()),
    fileExists(path)
  else { return nil }
  return URL(fileURLWithPath: path)
}

public enum ViewerMessage: Equatable, Sendable {
  public static let themeCommand = "theme"
  public static let stateQuery = "state"

  case open(URL)
  case theme
  case state
}

public func parseViewerMessage(_ line: String, fileExists: (String) -> Bool) -> ViewerMessage? {
  if line == ViewerMessage.themeCommand { return .theme }
  if line == ViewerMessage.stateQuery { return .state }
  return validateOpenMessage(line, fileExists: fileExists).map(ViewerMessage.open)
}

public enum EditRequestMode: String, Equatable, Sendable {
  case configured
  case alternate
}

public struct PluginEnvelope: Equatable, Sendable {
  public var token: String
  public var seq: Int
  public var file: String

  public init(token: String, seq: Int, file: String) {
    self.token = token
    self.seq = seq
    self.file = file
  }
}

public enum EditorMessage: Equatable, Sendable {
  case cursor(PluginEnvelope, line: Int, top: Int, height: Int)
  case buffer(PluginEnvelope, text: URL)
  case clean(PluginEnvelope)
  case follow(PluginEnvelope)
  case unlinked(PluginEnvelope)
  case exit(PluginEnvelope)
  case edit(mode: EditRequestMode, line: Int)

  public var envelope: PluginEnvelope? {
    switch self {
    case .cursor(let envelope, _, _, _), .buffer(let envelope, _), .clean(let envelope), .follow(let envelope),
      .unlinked(let envelope), .exit(let envelope):
      envelope
    case .edit: nil
    }
  }

  public static func editLine(mode: EditRequestMode, line: Int) -> String {
    jsonLine(["type": "edit", "mode": mode.rawValue, "line": line])
  }
}

public enum EditorControlCommand: Equatable, Sendable {
  case link(socket: String, token: String, file: String, line: Int)
  case jump(token: String, line: Int)

  public var wireLine: String {
    switch self {
    case .link(let socket, let token, let file, let line):
      jsonLine(["type": "link", "socket": socket, "token": token, "file": file, "line": line])
    case .jump(let token, let line):
      jsonLine(["type": "jump", "token": token, "line": line])
    }
  }

  public static func parse(_ line: String) -> EditorControlCommand? {
    guard let wire = decodeWire(line), let token = wire.token, !token.isEmpty, let lineNumber = wire.line,
      lineNumber >= 1
    else { return nil }
    switch wire.type {
    case "link":
      guard let socket = wire.socket, isAbsolutePath(socket), let file = wire.file, isAbsolutePath(file) else {
        return nil
      }
      return .link(socket: socket, token: token, file: file, line: lineNumber)
    case "jump":
      return .jump(token: token, line: lineNumber)
    default:
      return nil
    }
  }
}

private struct EditorWire: Decodable {
  var type: String
  var token: String?
  var file: String?
  var socket: String?
  var text: String?
  var mode: String?
  var seq: Int?
  var line: Int?
  var top: Int?
  var height: Int?
}

private func decodeWire(_ line: String) -> EditorWire? {
  guard line.utf8.count < maxOpenMessageBytes else { return nil }
  return try? JSONDecoder().decode(EditorWire.self, from: Data(line.utf8))
}

private func isAbsolutePath(_ path: String) -> Bool {
  path.hasPrefix("/") && !path.unicodeScalars.contains("\u{0}")
}

private func jsonLine(_ object: [String: Any]) -> String {
  let data =
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
  return String(decoding: data, as: UTF8.self)
}

public func validateBufferPath(_ path: String, buffersDirectory: URL) -> URL? {
  guard isAbsolutePath(path) else { return nil }
  let root = canonicalPath(buffersDirectory.path)
  let resolved = canonicalPath(path)
  var info = stat()
  guard resolved.hasPrefix(root + "/"), stat(resolved, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
    info.st_uid == geteuid()
  else { return nil }
  return URL(fileURLWithPath: resolved)
}

public func parseEditorMessage(_ line: String, buffersDirectory: URL?) -> EditorMessage? {
  guard let wire = decodeWire(line) else { return nil }
  if wire.type == "edit" {
    guard let mode = wire.mode.flatMap(EditRequestMode.init(rawValue:)), let lineNumber = wire.line, lineNumber >= 1
    else {
      return nil
    }
    return .edit(mode: mode, line: lineNumber)
  }
  guard let token = wire.token, !token.isEmpty, let seq = wire.seq, seq >= 0, let file = wire.file,
    isAbsolutePath(file)
  else { return nil }
  let envelope = PluginEnvelope(token: token, seq: seq, file: file)
  switch wire.type {
  case "cursor":
    guard let lineNumber = wire.line, lineNumber >= 1, let top = wire.top, top >= 1, let height = wire.height,
      height >= 1
    else { return nil }
    return .cursor(envelope, line: lineNumber, top: top, height: height)
  case "buffer":
    guard let buffersDirectory, let text = wire.text,
      let url = validateBufferPath(text, buffersDirectory: buffersDirectory)
    else { return nil }
    return .buffer(envelope, text: url)
  case "clean": return .clean(envelope)
  case "follow": return .follow(envelope)
  case "unlinked": return .unlinked(envelope)
  case "exit": return .exit(envelope)
  default: return nil
  }
}

public struct ViewerState: Codable, Equatable, Sendable {
  public var file: String?
  public var openedAt: Double
  public var opener: String?

  public init(file: String?, openedAt: Double, opener: String?) {
    self.file = file
    self.openedAt = openedAt
    self.opener = opener
  }

  enum CodingKeys: String, CodingKey {
    case file
    case openedAt = "opened_at"
    case opener
  }
}

public enum PreviewProbe: Equatable, Sendable {
  case answered(ViewerState)
  case silent
  case unreachable
}

public func socketAddress(path: String) -> sockaddr_un? {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8CString)
  let capacity = MemoryLayout.size(ofValue: address.sun_path)
  guard bytes.count <= capacity else { return nil }
  withUnsafeMutableBytes(of: &address.sun_path) { raw in
    bytes.withUnsafeBytes { raw.copyMemory(from: $0) }
  }
  return address
}

let socketTimeout = timeval(tv_sec: 1, tv_usec: 0)

func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
  var offset = 0
  while offset < bytes.count {
    let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    if written < 0, errno == EINTR { continue }
    guard written > 0 else { return false }
    offset += written
  }
  return true
}

public enum ViewerSocketClient {
  public static func sendTheme(to socket: URL) -> Bool {
    send(path: ViewerMessage.themeCommand, to: socket)
  }

  public static func send(path: String, to socket: URL) -> Bool {
    sendLine(path, to: socket)
  }

  public static func sendEdit(mode: EditRequestMode, line: Int, to socket: URL) -> Bool {
    sendLine(EditorMessage.editLine(mode: mode, line: line), to: socket)
  }

  public static func send(_ command: EditorControlCommand, to socket: URL) -> Bool {
    sendLine(command.wireLine, to: socket, unlinkOnRefused: false)
  }

  public static func sendLine(_ line: String, to socket: URL, unlinkOnRefused: Bool = true) -> Bool {
    guard let descriptor = connect(sending: line, to: socket, unlinkOnRefused: unlinkOnRefused) else { return false }
    close(descriptor)
    return true
  }

  public static func query(_ socket: URL) -> PreviewProbe {
    guard let descriptor = connect(sending: ViewerMessage.stateQuery, to: socket, unlinkOnRefused: true) else {
      return .unreachable
    }
    defer { close(descriptor) }
    var timeout = socketTimeout
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let deadline = Date().addingTimeInterval(TimeInterval(socketTimeout.tv_sec))
    var data = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while data.count < maxOpenMessageBytes, !data.contains(10), Date() < deadline {
      let count = read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { break }
      data += buffer[0..<count]
    }
    guard let end = data.firstIndex(of: 10),
      let state = try? JSONDecoder().decode(ViewerState.self, from: Data(data[..<end]))
    else { return .silent }
    return .answered(state)
  }

  private static func connect(sending line: String, to socket: URL, unlinkOnRefused: Bool) -> Int32? {
    let message = line + "\n"
    guard !line.unicodeScalars.contains("\u{0}"), message.utf8.count <= maxOpenMessageBytes,
      var address = socketAddress(path: socket.path)
    else { return nil }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    var noSigPipe: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var timeout = socketTimeout
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      if unlinkOnRefused, errno == ECONNREFUSED || errno == ENOTSOCK { unlink(socket.path) }
      close(descriptor)
      return nil
    }
    guard writeAll(descriptor, Array(message.utf8)) else {
      close(descriptor)
      return nil
    }
    return descriptor
  }
}
