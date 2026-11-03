import Darwin
import Dispatch
import Foundation

public enum HandoffSpawn {
  public static let defaultSignals: [Int32] = [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGWINCH, SIGTSTP, SIGPIPE]

  public struct Failure: Error, Equatable, CustomStringConvertible {
    public var step: String
    public var code: Int32

    public var description: String { "\(step) failed: \(String(cString: strerror(code)))" }
  }

  public static func spawn(
    _ command: [String], environment: [String: String], directory: URL?,
    standardIO: [Int32] = [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]
  ) throws -> pid_t {
    guard let executable = command.first, executable.hasPrefix("/") else {
      throw Failure(step: "posix_spawn", code: ENOENT)
    }
    var attributes: posix_spawnattr_t?
    try check("posix_spawnattr_init", posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    var actions: posix_spawn_file_actions_t?
    try check("posix_spawn_file_actions_init", posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }

    let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    try check("posix_spawnattr_setflags", posix_spawnattr_setflags(&attributes, Int16(flags)))
    var defaults = signalSet(defaultSignals)
    try check("posix_spawnattr_setsigdefault", posix_spawnattr_setsigdefault(&attributes, &defaults))
    var mask = signalSet([])
    try check("posix_spawnattr_setsigmask", posix_spawnattr_setsigmask(&attributes, &mask))

    for (target, source) in standardIO.enumerated() {
      let target = Int32(target)
      if source == target {
        try check("posix_spawn_file_actions_addinherit_np", posix_spawn_file_actions_addinherit_np(&actions, target))
      } else {
        try check("posix_spawn_file_actions_adddup2", posix_spawn_file_actions_adddup2(&actions, source, target))
      }
    }
    if let directory {
      try check(
        "posix_spawn_file_actions_addchdir_np", posix_spawn_file_actions_addchdir_np(&actions, directory.path))
    }

    let arguments = command.map { strdup($0) } + [nil]
    let variables = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for pointer in arguments + variables { free(pointer) }
    }
    var pid: pid_t = 0
    try check("posix_spawn", posix_spawn(&pid, executable, &actions, &attributes, arguments, variables))
    return pid
  }

  static func signalSet(_ signals: [Int32]) -> sigset_t {
    signals.reduce(sigset_t(0)) { $0 | (1 << sigset_t($1 - 1)) }
  }

  private static func check(_ step: String, _ result: Int32) throws {
    guard result == 0 else { throw Failure(step: step, code: result) }
  }
}

public final class HandoffChild: @unchecked Sendable {
  public let pid: pid_t
  private let onExit: (Int32) -> Void
  private var sources: [DispatchSourceProtocol] = []
  private var finished = false

  public init(pid: pid_t, queue: DispatchQueue = .main, onExit: @escaping (Int32) -> Void) {
    self.pid = pid
    self.onExit = onExit
    let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: [.exit, .signal], queue: queue)
    let childSignal = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: queue)
    sources = [process, childSignal]
    for source in sources {
      source.setEventHandler { [weak self] in self?.poll() }
      source.resume()
    }
    queue.async { [weak self] in self?.poll() }
  }

  deinit {
    for source in sources { source.cancel() }
  }

  public static func exitCode(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
  }

  private func poll() {
    guard !finished else { return }
    var status: Int32 = 0
    let result = waitpid(pid, &status, WNOHANG | WUNTRACED)
    if result == 0 || (result < 0 && errno == EINTR) { return }
    if result == pid, status & 0xff == 0x7f {
      kill(pid, SIGCONT)
      return
    }
    finished = true
    for source in sources { source.cancel() }
    sources = []
    onExit(result == pid ? Self.exitCode(status) : 1)
  }
}
