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

public enum ViewerSocketClient {
  public static func send(path: String, to socket: URL) -> Bool {
    let message = path + "\n"
    guard !path.unicodeScalars.contains("\u{0}"), message.utf8.count <= maxOpenMessageBytes,
      var address = socketAddress(path: socket.path)
    else { return false }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var noSigPipe: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      if errno == ECONNREFUSED || errno == ENOTSOCK { unlink(socket.path) }
      return false
    }
    let bytes = Array(message.utf8)
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
      if written < 0, errno == EINTR { continue }
      guard written > 0 else { return false }
      offset += written
    }
    return true
  }
}
