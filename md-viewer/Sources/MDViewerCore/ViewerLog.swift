import Foundation

public final class ViewerLog: @unchecked Sendable {
  public static let maximumBytes = 512 * 1024

  public let url: URL
  private let lock = NSLock()
  private let now: () -> Date

  public init(url: URL, now: @escaping () -> Date = Date.init) {
    self.url = url
    self.now = now
  }

  public func write(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: now())
    let line = Data("\(stamp) [\(getpid())] \(message)\n".utf8)
    lock.lock()
    defer { lock.unlock() }
    let manager = FileManager.default
    try? manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    if size.map({ $0 + line.count > Self.maximumBytes }) ?? true {
      manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: line)
  }
}
