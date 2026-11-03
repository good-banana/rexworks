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
    guard let descriptor = connect(sending: path, to: socket) else { return false }
    close(descriptor)
    return true
  }

  public static func query(_ socket: URL) -> PreviewProbe {
    guard let descriptor = connect(sending: ViewerMessage.stateQuery, to: socket) else { return .unreachable }
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

  private static func connect(sending line: String, to socket: URL) -> Int32? {
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
      if errno == ECONNREFUSED || errno == ENOTSOCK { unlink(socket.path) }
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
