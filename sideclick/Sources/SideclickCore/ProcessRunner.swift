import Foundation

public struct CommandResult: Equatable, Sendable {
  public var status: Int32
  public var stdout: Data
  public var stderr: Data

  public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
  }

  public var stderrText: String {
    String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public protocol CommandRunning: Sendable {
  func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
}

public struct ProcessRunner: CommandRunning {
  public var timeout: TimeInterval
  public var killGrace: TimeInterval

  public init(timeout: TimeInterval = 15, killGrace: TimeInterval = 2) {
    self.timeout = timeout
    self.killGrace = killGrace
  }

  public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
    let stdout = try CaptureFile()
    let stderr = try CaptureFile()
    defer {
      stdout.remove()
      stderr.remove()
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout.handle
    process.standardError = stderr.handle
    try process.run()

    let terminate = DispatchWorkItem { [process] in
      if process.isRunning { process.terminate() }
    }
    let kill = DispatchWorkItem { [process] in
      if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminate)
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout + killGrace, execute: kill)
    process.waitUntilExit()
    terminate.cancel()
    kill.cancel()
    return CommandResult(
      status: process.terminationStatus, stdout: try stdout.contents(), stderr: try stderr.contents())
  }
}

private struct CaptureFile {
  let url: URL
  let handle: FileHandle

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent("sideclick-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    handle = try FileHandle(forUpdating: url)
  }

  func contents() throws -> Data {
    try Data(contentsOf: url)
  }

  func remove() {
    try? handle.close()
    try? FileManager.default.removeItem(at: url)
  }
}
