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
    guard let id = neovimID(of: entry),
      let text = try? String(contentsOf: paths.neovimFiles(id: id), encoding: .utf8)
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

  public func withLock<T>(_ body: (OpenLock) throws -> T) throws -> T {
    guard let lock = OpenLock.acquire(paths.editLock, timeout: lockTimeout) else {
      throw EditorRegistryError.lockUnavailable
    }
    defer { lock.release() }
    return try body(lock)
  }

  public func lookup(
    file: String, session: String, under lock: OpenLock, blockState: (String) -> BlockState
  ) throws -> EditorEntry? {
    for candidate in entries(listing: file, session: session) {
      if blockState(candidate.block) == .notFound {
        try remove(block: candidate.block, under: lock)
      } else {
        return candidate
      }
    }
    return nil
  }

  @discardableResult
  public func prune(under lock: OpenLock, blockState: (String) -> BlockState) throws -> [EditorEntry] {
    var pruned: [EditorEntry] = []
    for entry in entries() where blockState(entry.block) == .notFound {
      if try remove(block: entry.block, under: lock) != nil { pruned.append(entry) }
    }
    return pruned
  }

  public func write(_ entry: EditorEntry, under lock: OpenLock) throws {
    try FileManager.default.createDirectory(
      at: paths.editorsDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try PrivateFile.write(JSONEncoder().encode(entry), to: entryFile(block: entry.block))
  }

  @discardableResult
  public func addFile(_ file: String, block: String, under lock: OpenLock) throws -> Bool {
    try update(block: block, under: lock) { entry in
      let canonical = canonicalPath(file)
      if !entry.files.contains(canonical) { entry.files.append(canonical) }
    }
  }

  @discardableResult
  public func setPreview(_ preview: String?, block: String, under lock: OpenLock) throws -> Bool {
    try update(block: block, under: lock) { $0.preview = preview }
  }

  @discardableResult
  public func remove(block: String, under lock: OpenLock) throws -> EditorEntry? {
    guard let entry = entry(block: block) else { return nil }
    let manager = FileManager.default
    try manager.removeItem(at: entryFile(block: block))
    if let id = neovimID(of: entry) {
      try? manager.removeItem(at: paths.neovimFiles(id: id))
      try? manager.removeItem(at: paths.neovimControlSocket(id: id))
    }
    return entry
  }

  private func update(block: String, under lock: OpenLock, _ change: (inout EditorEntry) -> Void) throws -> Bool {
    guard var entry = entry(block: block) else { return false }
    let before = entry
    change(&entry)
    if entry != before { try write(entry, under: lock) }
    return true
  }

  private func neovimID(of entry: EditorEntry) -> String? {
    guard let socket = entry.controlSocket else { return nil }
    let url = URL(fileURLWithPath: socket).standardizedFileURL
    let directory = paths.neovimSocketsDirectory.standardizedFileURL
    let id = url.deletingPathExtension().lastPathComponent
    guard url.pathExtension == "sock", url.deletingLastPathComponent().path == directory.path,
      !id.isEmpty, !id.hasPrefix(".")
    else { return nil }
    return id
  }
}

public enum EditorRegistryError: Error, Equatable, CustomStringConvertible {
  case lockUnavailable

  public var description: String { "Could not lock the editor registry" }
}
