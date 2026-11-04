import Darwin
import Foundation

public final class OpenLock {
  public static let defaultTimeout: TimeInterval = 5
  static let pollInterval: TimeInterval = 0.02

  private var descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit { release() }

  public static func acquire(_ url: URL, timeout: TimeInterval = defaultTimeout) -> OpenLock? {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let code = errno
      guard code == EINTR || (code == EWOULDBLOCK && Date() < deadline) else {
        close(descriptor)
        return nil
      }
      if code == EWOULDBLOCK { Thread.sleep(forTimeInterval: pollInterval) }
    }
    return OpenLock(descriptor: descriptor)
  }

  public static func holding<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
    let lock = acquire(url)
    defer { lock?.release() }
    return try body()
  }

  public func release() {
    guard descriptor >= 0 else { return }
    close(descriptor)
    descriptor = -1
  }
}
