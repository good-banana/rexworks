import Foundation

public protocol ProcessRunning {
  func run(_ executable: String, _ arguments: [String]) throws -> (
    status: Int32, stdout: Data, stderr: Data
  )
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

  public func run(_ executable: String, _ arguments: [String]) throws -> (
    status: Int32, stdout: Data, stderr: Data
  ) {
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

    let group = DispatchGroup()
    let stdoutBox = DataBox()
    let stderrBox = DataBox()
    for (pipe, box) in [(outPipe, stdoutBox), (errPipe, stderrBox)] {
      group.enter()
      DispatchQueue.global().async {
        box.set(pipe.fileHandleForReading.readDataToEndOfFile())
        group.leave()
      }
    }

    if finished.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      _ = finished.wait(timeout: .now() + 2)
      throw ProcessRunnerError(message: "\(executable) timed out after \(Int(timeout)) seconds")
    }
    group.wait()
    return (process.terminationStatus, stdoutBox.value, stderrBox.value)
  }
}

private final class DataBox: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  var value: Data { lock.withLock { data } }

  func set(_ newValue: Data) {
    lock.withLock { data = newValue }
  }
}
