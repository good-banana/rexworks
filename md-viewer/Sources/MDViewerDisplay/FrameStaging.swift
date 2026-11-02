import Darwin
import Foundation
import MDViewerCore
import MDViewerSystem

public enum StagingError: Error, Equatable, LocalizedError {
  case directory(String)
  case create(String, Int32)
  case write(String, Int32)

  public var errorDescription: String? {
    switch self {
    case .directory(let path): "could not create frame directory \(path)"
    case .create(let name, let code): "could not create frame \(name): \(String(cString: strerror(code)))"
    case .write(let name, let code): "could not write frame \(name): \(String(cString: strerror(code)))"
    }
  }
}

public struct StagedFrame: Equatable, Sendable {
  public var medium: Kitty.Medium
  public var sequence: UInt64

  public init(medium: Kitty.Medium, sequence: UInt64) {
    self.medium = medium
    self.sequence = sequence
  }
}

public protocol FrameStager: AnyObject {
  var name: String { get }
  var outstanding: Int { get }
  func stage(_ bytes: UnsafeRawBufferPointer, at now: UInt64) throws -> StagedFrame
  func acknowledge(through sequence: UInt64)
  func reclaim(olderThan cutoff: UInt64)
  func removeAll()
}

final class StagedItems {
  struct Item {
    var sequence: UInt64
    var name: String
    var created: UInt64
  }

  private(set) var items: [Item] = []
  private var nextSequence: UInt64 = 1

  func add(_ name: String, at now: UInt64) -> UInt64 {
    let sequence = nextSequence
    nextSequence += 1
    items.append(Item(sequence: sequence, name: name, created: now))
    return sequence
  }

  func take(where predicate: (Item) -> Bool) -> [String] {
    let taken = items.filter(predicate).map(\.name)
    items.removeAll(where: predicate)
    return taken
  }
}

public final class TemporaryFileStager: FrameStager {
  public static let directoryPrefix = "tty-graphics-protocol-md-viewer-frames-"

  public let directory: URL
  public var name: String { "file" }
  public var outstanding: Int { items.items.count }
  private let items = StagedItems()
  private var fileNumber = 0

  public init(parent: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)) throws {
    Self.sweepAbandoned(in: parent)
    directory = parent.appendingPathComponent("\(Self.directoryPrefix)\(getpid())", isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    guard mkdir(directory.path, 0o700) == 0 else { throw StagingError.directory(directory.path) }
    ExitCleanup.shared.add(directory: directory.path)
  }

  deinit {
    removeAll()
  }

  public func stage(_ bytes: UnsafeRawBufferPointer, at now: UInt64) throws -> StagedFrame {
    fileNumber += 1
    let path = directory.appendingPathComponent("\(fileNumber).rgba").path
    let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw StagingError.create(path, errno) }
    defer { close(descriptor) }
    var offset = 0
    while offset < bytes.count {
      let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      if written < 0 {
        if errno == EINTR { continue }
        let code = errno
        unlink(path)
        throw StagingError.write(path, code)
      }
      offset += written
    }
    return StagedFrame(medium: .temporaryFile(path), sequence: items.add(path, at: now))
  }

  public func acknowledge(through sequence: UInt64) {
    for path in items.take(where: { $0.sequence <= sequence }) { unlink(path) }
  }

  public func reclaim(olderThan cutoff: UInt64) {
    for path in items.take(where: { $0.created < cutoff }) { unlink(path) }
  }

  public func removeAll() {
    _ = items.take { _ in true }
    try? FileManager.default.removeItem(at: directory)
    ExitCleanup.shared.remove(directory: directory.path)
  }

  static func sweepAbandoned(in parent: URL) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
    for name in names where name.hasPrefix(directoryPrefix) {
      guard let pid = Int32(name.dropFirst(directoryPrefix.count)), pid != getpid() else { continue }
      if kill(pid, 0) != 0, errno == ESRCH {
        try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
      }
    }
  }
}

public final class SharedMemoryStager: FrameStager {
  public var name: String { "shm" }
  public var outstanding: Int { items.items.count }
  private let prefix: String
  private let items = StagedItems()
  private var number = 0

  public static func defaultPrefix() -> String {
    "/mdv\(getpid())-\(String(arc4random() & 0xff_ffff, radix: 36))-"
  }

  public init(prefix: String = SharedMemoryStager.defaultPrefix()) {
    self.prefix = prefix
  }

  deinit {
    removeAll()
  }

  public func stage(_ bytes: UnsafeRawBufferPointer, at now: UInt64) throws -> StagedFrame {
    number += 1
    let name = "\(prefix)\(number)"
    let descriptor = mdv_shm_create(name, 0o600)
    guard descriptor >= 0 else { throw StagingError.create(name, errno) }
    defer { close(descriptor) }
    ExitCleanup.shared.add(sharedMemory: name)
    guard ftruncate(descriptor, off_t(bytes.count)) == 0,
      let map = mmap(nil, bytes.count, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), map != MAP_FAILED
    else {
      let code = errno
      shm_unlink(name)
      ExitCleanup.shared.remove(sharedMemory: name)
      throw StagingError.write(name, code)
    }
    map.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
    munmap(map, bytes.count)
    return StagedFrame(medium: .sharedMemory(name), sequence: items.add(name, at: now))
  }

  public func acknowledge(through sequence: UInt64) {
    release(items.take { $0.sequence <= sequence })
  }

  public func reclaim(olderThan cutoff: UInt64) {
    release(items.take { $0.created < cutoff })
  }

  public func removeAll() {
    release(items.take { _ in true })
  }

  private func release(_ names: [String]) {
    for name in names {
      shm_unlink(name)
      ExitCleanup.shared.remove(sharedMemory: name)
    }
  }
}

public final class ExitCleanup: @unchecked Sendable {
  public static let shared = ExitCleanup()

  private let lock = NSLock()
  private var directories: Set<String> = []
  private var sharedMemory: Set<String> = []
  private var registered = false

  public var isEmpty: Bool {
    lock.withLock { directories.isEmpty && sharedMemory.isEmpty }
  }

  func add(directory: String) {
    lock.withLock { _ = directories.insert(directory) }
    registerOnce()
  }

  func remove(directory: String) {
    lock.withLock { _ = directories.remove(directory) }
  }

  func add(sharedMemory name: String) {
    lock.withLock { _ = sharedMemory.insert(name) }
    mdv_crash_track_shm(name)
    registerOnce()
  }

  func remove(sharedMemory name: String) {
    lock.withLock { _ = sharedMemory.remove(name) }
    mdv_crash_untrack_shm(name)
  }

  public func run() {
    let (paths, names) = lock.withLock {
      defer {
        directories = []
        sharedMemory = []
      }
      return (directories, sharedMemory)
    }
    for path in paths { try? FileManager.default.removeItem(atPath: path) }
    for name in names { shm_unlink(name) }
  }

  private func registerOnce() {
    let first = lock.withLock {
      defer { registered = true }
      return !registered
    }
    if first { atexit { ExitCleanup.shared.run() } }
  }
}

public enum FrameStaging {
  public static func preferred() -> (primary: FrameStager, fallback: FrameStager?) {
    (SharedMemoryStager(), try? TemporaryFileStager())
  }
}
