import Darwin
import Foundation

public enum PrivateFile {
  public static let mode: mode_t = 0o600

  public static func write(_ data: Data, to url: URL) throws {
    try write(data, to: url, beforeRename: { _ in })
  }

  static func write(_ data: Data, to url: URL, beforeRename: (URL) throws -> Void) throws {
    let temp = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp")
    let descriptor = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, mode)
    guard descriptor >= 0 else { throw posixError(temp) }
    do {
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      guard fchmod(descriptor, mode) == 0 else { throw posixError(temp) }
      try handle.write(contentsOf: data)
      try handle.close()
      try beforeRename(temp)
      guard rename(temp.path, url.path) == 0 else { throw posixError(url) }
    } catch {
      unlink(temp.path)
      throw error
    }
  }

  public static func restrict(_ url: URL) throws {
    let current = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    guard current != Int(mode) else { return }
    try FileManager.default.setAttributes([.posixPermissions: Int(mode)], ofItemAtPath: url.path)
  }

  private static func posixError(_ url: URL) -> Error {
    let code = errno
    return NSError(
      domain: NSPOSIXErrorDomain, code: Int(code),
      userInfo: [NSFilePathErrorKey: url.path, NSLocalizedDescriptionKey: String(cString: strerror(code))])
  }
}
