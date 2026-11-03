import Darwin
import Foundation

private final class SocketFileRegistry: @unchecked Sendable {
  static let shared = SocketFileRegistry()
  private let lock = NSLock()
  private var paths: Set<String> = []
  private var installedExitHook = false
  private var stagingCounter = 0

  func stagingName() -> String {
    lock.withLock {
      stagingCounter += 1
      return ".\(getpid())-\(stagingCounter)"
    }
  }

  func add(_ path: String) {
    lock.lock()
    paths.insert(path)
    let needsHook = !installedExitHook
    installedExitHook = true
    lock.unlock()
    if needsHook { atexit { removeViewerSocketFiles() } }
  }

  func remove(_ path: String) {
    lock.lock()
    paths.remove(path)
    lock.unlock()
  }

  func takeAll() -> Set<String> {
    lock.lock()
    defer { lock.unlock() }
    let all = paths
    paths = []
    return all
  }
}

func removeViewerSocketFiles() {
  for path in SocketFileRegistry.shared.takeAll() { unlink(path) }
}

public final class ViewerStatus: @unchecked Sendable {
  private let lock = NSLock()
  private let openedAt: Double
  private let opener: String?
  private var file: URL?

  public init(file: URL? = nil, opener: String?, openedAt: Double = Date().timeIntervalSince1970) {
    self.file = file
    self.opener = opener
    self.openedAt = openedAt
  }

  public func show(_ file: URL) {
    lock.withLock { self.file = file }
  }

  public var state: ViewerState {
    lock.withLock { ViewerState(file: file?.path, openedAt: openedAt, opener: opener) }
  }
}

public final class ViewerSocketServer: @unchecked Sendable {
  private let socketURL: URL
  private let status: ViewerStatus?
  private let onOpen: (URL) -> Void
  private let onTheme: () -> Void
  private let onEditor: (EditorMessage) -> Void
  private let buffersDirectory: URL?
  private let descriptor: Int32
  private let source: DispatchSourceRead
  private let queue = DispatchQueue(label: "md-viewer.socket")

  public struct BindError: Error, CustomStringConvertible {
    public let description: String
  }

  public var path: URL { socketURL }

  public init(
    socket: URL, status: ViewerStatus? = nil, buffersDirectory: URL? = nil, onOpen: @escaping (URL) -> Void,
    onTheme: @escaping () -> Void = {}, onEditor: @escaping (EditorMessage) -> Void = { _ in }
  ) throws {
    socketURL = socket
    self.status = status
    self.onOpen = onOpen
    self.onTheme = onTheme
    self.onEditor = onEditor
    self.buffersDirectory = buffersDirectory
    try FileManager.default.createDirectory(
      at: socket.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let staging = socket.deletingLastPathComponent().appendingPathComponent(SocketFileRegistry.shared.stagingName())
    guard socketAddress(path: socket.path) != nil, var address = socketAddress(path: staging.path) else {
      throw BindError(description: "socket path too long")
    }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BindError(description: "socket failed: \(errno)") }
    unlink(staging.path)
    let previousMask = umask(0o177)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    umask(previousMask)
    guard bound == 0, chmod(staging.path, 0o600) == 0, listen(fd, SOMAXCONN) == 0,
      rename(staging.path, socket.path) == 0
    else {
      let code = errno
      Darwin.close(fd)
      unlink(staging.path)
      throw BindError(description: "could not listen on \(socket.path): \(code)")
    }
    descriptor = fd
    SocketFileRegistry.shared.add(socket.path)
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.accept() }
    source.resume()
  }

  public func close() {
    source.cancel()
    Darwin.close(descriptor)
    unlink(socketURL.path)
    SocketFileRegistry.shared.remove(socketURL.path)
  }

  private func accept() {
    let client = Darwin.accept(descriptor, nil, nil)
    guard client >= 0 else { return }
    defer { Darwin.close(client) }
    var timeout = socketTimeout
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var data = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while data.count < maxOpenMessageBytes, !data.contains(10) {
      let count = read(client, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { break }
      data += buffer[0..<count]
    }
    let first = data.prefix(maxOpenMessageBytes).prefix { $0 != 10 }
    let line = String(decoding: first, as: UTF8.self)
    if line.hasPrefix("{") {
      if let message = parseEditorMessage(line, buffersDirectory: buffersDirectory) { onEditor(message) }
      return
    }
    switch parseViewerMessage(line, fileExists: isRegularFile) {
    case .open(let url): onOpen(url)
    case .theme: onTheme()
    case .state: reply(client)
    case nil: break
    }
  }

  private func reply(_ client: Int32) {
    guard let status, let json = try? JSONEncoder().encode(status.state) else { return }
    _ = writeAll(client, Array(json) + [10])
  }
}

public func isRegularFile(_ path: String) -> Bool {
  var info = stat()
  return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
}
