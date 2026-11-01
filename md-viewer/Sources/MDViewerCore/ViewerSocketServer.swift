import Darwin
import Foundation

public final class ViewerSocketServer: @unchecked Sendable {
  private let socketURL: URL
  private let onOpen: (URL) -> Void
  private let descriptor: Int32
  private let source: DispatchSourceRead
  private let queue = DispatchQueue(label: "md-viewer.socket")

  public struct BindError: Error, CustomStringConvertible {
    public let description: String
  }

  public init(socket: URL, onOpen: @escaping (URL) -> Void) throws {
    socketURL = socket
    self.onOpen = onOpen
    try FileManager.default.createDirectory(
      at: socket.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard var address = socketAddress(path: socket.path) else { throw BindError(description: "socket path too long") }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BindError(description: "socket failed: \(errno)") }
    unlink(socket.path)
    let previousMask = umask(0o177)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    umask(previousMask)
    guard bound == 0, chmod(socket.path, 0o600) == 0, listen(fd, 8) == 0 else {
      let code = errno
      Darwin.close(fd)
      unlink(socket.path)
      throw BindError(description: "could not listen on \(socket.path): \(code)")
    }
    descriptor = fd
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.accept() }
    source.resume()
  }

  public func close() {
    source.cancel()
    Darwin.close(descriptor)
    unlink(socketURL.path)
  }

  private func accept() {
    let client = Darwin.accept(descriptor, nil, nil)
    guard client >= 0 else { return }
    defer { Darwin.close(client) }
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var data = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while data.count < maxOpenMessageBytes, !data.contains(10) {
      let count = read(client, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { break }
      data += buffer[0..<count]
    }
    let first = data.prefix(maxOpenMessageBytes).prefix { $0 != 10 }
    guard let url = validateOpenMessage(String(decoding: first, as: UTF8.self), fileExists: isRegularFile)
    else { return }
    onOpen(url)
  }
}

public func isRegularFile(_ path: String) -> Bool {
  var info = stat()
  return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
}
