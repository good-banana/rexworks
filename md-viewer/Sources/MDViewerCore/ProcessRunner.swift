import Foundation

public protocol ProcessRunning {
  func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> (
    status: Int32, stdout: Data, stderr: Data
  )
}

extension ProcessRunning {
  public func run(_ executable: String, _ arguments: [String]) throws -> (
    status: Int32, stdout: Data, stderr: Data
  ) {
    try run(executable, arguments, timeout: nil)
  }
}

public struct ProcessRunnerError: Error, Equatable, CustomStringConvertible {
  public let message: String
  public var description: String { message }
}

public struct ProcessRunner: ProcessRunning {
  public var timeout: TimeInterval

  public init(timeout: TimeInterval = 15) {
    self.timeout = timeout
  }

  public func run(_ executable: String, _ arguments: [String], timeout callTimeout: TimeInterval?) throws -> (
    status: Int32, stdout: Data, stderr: Data
  ) {
    let limit = callTimeout ?? timeout
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    process.standardInput = FileHandle.nullDevice

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
      try process.run()
    } catch {
      throw ProcessRunnerError(message: "cannot launch \(executable): \(error.localizedDescription)")
    }

    let deadline = DispatchTime.now() + max(limit, 0)
    let group = DispatchGroup()
    let stdoutReader = PipeReader(outPipe.fileHandleForReading, group: group)
    let stderrReader = PipeReader(errPipe.fileHandleForReading, group: group)

    if finished.wait(timeout: deadline) == .timedOut {
      stdoutReader.stop()
      stderrReader.stop()
      process.terminate()
      if finished.wait(timeout: .now() + 0.1) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 0.1)
      }
      throw ProcessRunnerError(message: "\(executable) timed out after \(limit) seconds")
    }
    _ = group.wait(timeout: min(.now() + Self.outputGrace, deadline))
    stdoutReader.stop()
    stderrReader.stop()
    return (process.terminationStatus, stdoutReader.data, stderrReader.data)
  }

  static let outputGrace: TimeInterval = 0.2
}

private final class PipeReader: @unchecked Sendable {
  private let lock = NSLock()
  private let handle: FileHandle
  private let group: DispatchGroup
  private var buffer = Data()
  private var stopped = false

  init(_ handle: FileHandle, group: DispatchGroup) {
    self.handle = handle
    self.group = group
    group.enter()
    handle.readabilityHandler = { [weak self] _ in self?.drain() }
  }

  var data: Data { lock.withLock { buffer } }

  func stop() {
    lock.withLock {
      guard !stopped else { return }
      stopped = true
      handle.readabilityHandler = nil
      try? handle.close()
      group.leave()
    }
  }

  private func drain() {
    lock.withLock {
      guard !stopped else { return }
      let chunk = handle.availableData
      if chunk.isEmpty {
        stopped = true
        handle.readabilityHandler = nil
        try? handle.close()
        group.leave()
      } else {
        buffer.append(chunk)
      }
    }
  }
}
