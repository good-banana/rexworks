import Foundation

public enum ManagedFileError: Error, Equatable, CustomStringConvertible {
  case unreadable(String)
  case notUTF8
  case unterminatedBlock
  case checkFailed(String)

  public var description: String {
    switch self {
    case .unreadable(let reason): "it could not be read (\(reason))"
    case .notUTF8: "it is not valid UTF-8"
    case .unterminatedBlock: "it has an md-viewer begin marker without the end marker"
    case .checkFailed(let output): "the edited file did not pass its check: \(output)"
    }
  }
}

public struct ManagedBlock: Sendable, Equatable {
  public let beginMarker: String
  public let endMarker: String
  public let text: String

  public init(beginMarker: String, endMarker: String, body: String) {
    self.beginMarker = beginMarker
    self.endMarker = endMarker
    self.text = "\(beginMarker)\n\(body)\n\(endMarker)"
  }

  public func isPresent(in text: String) -> Bool {
    text.components(separatedBy: "\n").contains(beginMarker)
  }

  func isCurrent(in text: String) -> Bool {
    let lines = text.components(separatedBy: "\n")
    let wanted = self.text.components(separatedBy: "\n")
    let starts = lines.indices.filter { lines[$0] == beginMarker }
    guard starts.count == 1, let start = starts.first, start + wanted.count <= lines.count else { return false }
    return Array(lines[start..<start + wanted.count]) == wanted
  }

  public func removing(from text: String) throws -> String {
    var lines = text.components(separatedBy: "\n")
    while let start = lines.firstIndex(of: beginMarker) {
      guard let end = lines[start...].firstIndex(of: endMarker) else { throw ManagedFileError.unterminatedBlock }
      lines.removeSubrange(start...end)
      if start > 0, start <= lines.count, lines[start - 1].isEmpty, start == lines.count || lines[start].isEmpty {
        lines.remove(at: start - 1)
      }
    }
    return lines.joined(separator: "\n")
  }

  public func installing(into text: String) throws -> String {
    var kept = try removing(from: text)
    if isCurrent(in: text) { return text }
    while kept.hasSuffix("\n\n") { kept.removeLast() }
    if kept.isEmpty { return self.text + "\n" }
    return kept + (kept.hasSuffix("\n") ? "\n" : "\n\n") + self.text + "\n"
  }
}

public enum ManagedFile {
  public static func read(_ url: URL) throws -> String? {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch {
      throw ManagedFileError.unreadable(error.localizedDescription)
    }
    guard let text = String(data: data, encoding: .utf8) else { throw ManagedFileError.notUTF8 }
    return text
  }

  public static func fsync(_ url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }

  @discardableResult
  public static func edit(
    _ configured: URL, synchronize: (URL) throws -> Void = fsync, checksCandidate: (URL) -> Bool = { _ in false },
    check: (URL) throws -> Void = { _ in }, change: (String?) throws -> String?
  ) throws -> Bool {
    let url = configured.resolvingSymlinksInPath()
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
      throw ManagedFileError.unreadable("it is a symbolic link to a file that does not exist")
    }
    let existing = try read(url)
    guard let updated = try change(existing), updated != existing else { return false }
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let candidate = directory.appendingPathComponent(".\(url.lastPathComponent).md-viewer-\(UUID().uuidString)")
    try Data(updated.utf8).write(to: candidate, options: .withoutOverwriting)
    do {
      let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o644
      try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: candidate.path)
      try synchronize(candidate)
      if checksCandidate(url) { try check(candidate) }
      guard rename(candidate.path, url.path) == 0 else {
        throw ManagedFileError.unreadable(String(cString: strerror(errno)))
      }
    } catch {
      try? FileManager.default.removeItem(at: candidate)
      throw error
    }
    return true
  }
}
