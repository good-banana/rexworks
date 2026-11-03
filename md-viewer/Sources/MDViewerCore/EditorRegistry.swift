import CryptoKit
import Foundation

public struct EditorEntry: Codable, Equatable, Sendable {
  public var block: String
  public var mode: EditMode
  public var session: String
  public var files: [String]
  public var kind: EditorKind
  public var controlSocket: String?
  public var preview: String?

  public init(
    block: String, mode: EditMode, session: String, files: [String], kind: EditorKind,
    controlSocket: String? = nil, preview: String? = nil
  ) {
    self.block = block
    self.mode = mode
    self.session = session
    self.files = files.map(canonicalPath)
    self.kind = kind
    self.controlSocket = controlSocket
    self.preview = preview
  }
}

public struct EditorRegistry: Sendable {
  public let paths: SupportPaths
  public let lockTimeout: TimeInterval

  public init(paths: SupportPaths, lockTimeout: TimeInterval = OpenLock.defaultTimeout) {
    self.paths = paths
    self.lockTimeout = lockTimeout
  }

  public func entryFile(block: String) -> URL {
    let digest = SHA256.hash(data: Data(block.utf8))
    let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return paths.editorsDirectory.appendingPathComponent("\(name).json")
  }

  public func entries() -> [EditorEntry] {
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: paths.editorsDirectory, includingPropertiesForKeys: nil)) ?? []
    return urls.filter { $0.pathExtension == "json" }
      .compactMap { try? JSONDecoder().decode(EditorEntry.self, from: Data(contentsOf: $0)) }
      .sorted { $0.block < $1.block }
  }

  public func entry(block: String) -> EditorEntry? {
    guard let data = try? Data(contentsOf: entryFile(block: block)) else { return nil }
    return try? JSONDecoder().decode(EditorEntry.self, from: data)
  }

  public func sidecarFiles(of entry: EditorEntry) -> [String] {
    guard let sidecar = sidecar(of: entry),
      let text = try? String(contentsOf: sidecar, encoding: .utf8)
    else { return [] }
    return text.split(separator: "\n").map { canonicalPath(String($0)) }
  }

  public func files(of entry: EditorEntry) -> Set<String> {
    Set(entry.files.map(canonicalPath)).union(sidecarFiles(of: entry))
  }

  public func entries(listing file: String, session: String) -> [EditorEntry] {
    let wanted = canonicalPath(file)
    return entries().filter { $0.session == session && files(of: $0).contains(wanted) }
  }

  public func lookup(
    file: String, session: String, under lock: OpenLock? = nil, blockState: (String) -> BlockState
  ) -> EditorEntry? {
    for candidate in entries(listing: file, session: session) {
      if blockState(candidate.block) == .notFound {
        remove(block: candidate.block, under: lock)
      } else {
        return candidate
      }
    }
    return nil
  }

  @discardableResult
  public func prune(under lock: OpenLock? = nil, blockState: (String) -> BlockState) -> [EditorEntry] {
    entries().filter { blockState($0.block) == .notFound }.map { entry in
      remove(block: entry.block, under: lock)
      return entry
    }
  }

  public func write(_ entry: EditorEntry, under lock: OpenLock? = nil) throws {
    try locked(lock) { _ in
      try FileManager.default.createDirectory(
        at: paths.editorsDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let file = entryFile(block: entry.block)
      try JSONEncoder().encode(entry).write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
  }

  @discardableResult
  public func addFile(_ file: String, block: String, under lock: OpenLock? = nil) throws -> Bool {
    try update(block: block, under: lock) { entry in
      let canonical = canonicalPath(file)
      if !entry.files.contains(canonical) { entry.files.append(canonical) }
    }
  }

  @discardableResult
  public func setPreview(_ preview: String?, block: String, under lock: OpenLock? = nil) throws -> Bool {
    try update(block: block, under: lock) { $0.preview = preview }
  }

  @discardableResult
  public func remove(block: String, under lock: OpenLock? = nil) -> EditorEntry? {
    let removed = try? locked(lock) { _ -> EditorEntry? in
      guard let entry = entry(block: block) else { return nil }
      let manager = FileManager.default
      try? manager.removeItem(at: entryFile(block: block))
      if let sidecar = sidecar(of: entry) { try? manager.removeItem(at: sidecar) }
      if let socket = entry.controlSocket { try? manager.removeItem(atPath: socket) }
      return entry
    }
    return removed ?? nil
  }

  private func update(block: String, under lock: OpenLock?, _ change: (inout EditorEntry) -> Void) throws -> Bool {
    try locked(lock) { held in
      guard var entry = entry(block: block) else { return false }
      let before = entry
      change(&entry)
      if entry != before { try write(entry, under: held) }
      return true
    }
  }

  private func sidecar(of entry: EditorEntry) -> URL? {
    guard let socket = entry.controlSocket else { return nil }
    let url = URL(fileURLWithPath: socket)
    guard url.pathExtension == "sock" else { return nil }
    return url.deletingPathExtension().appendingPathExtension("files")
  }

  private func locked<T>(_ held: OpenLock?, _ body: (OpenLock) throws -> T) throws -> T {
    if let held { return try body(held) }
    guard let lock = OpenLock.acquire(paths.editLock, timeout: lockTimeout) else {
      throw EditorRegistryError.lockUnavailable
    }
    defer { lock.release() }
    return try body(lock)
  }
}

public enum EditorRegistryError: Error, Equatable, CustomStringConvertible {
  case lockUnavailable

  public var description: String { "Could not lock the editor registry" }
}
