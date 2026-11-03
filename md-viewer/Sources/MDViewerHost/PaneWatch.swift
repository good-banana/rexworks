import Foundation
import MDViewerCore

public protocol PaneWaitProcess: AnyObject, Sendable {
  func stop()
}

public typealias PaneWaitLauncher =
  @Sendable (_ arguments: [String], _ finished: @escaping @Sendable (Data) -> Void) -> PaneWaitProcess?

public final class RexWaitProcess: PaneWaitProcess, @unchecked Sendable {
  private let process = Process()
  private let lock = NSLock()
  private let finished: @Sendable (Data) -> Void
  private var data = Data()
  private var outputClosed = false
  private var exited = false
  private var stopped = false

  public static func launcher(rexPath: String) -> PaneWaitLauncher {
    { arguments, finished in RexWaitProcess(executable: rexPath, arguments: arguments, finished: finished) }
  }

  public init?(executable: String, arguments: [String], finished: @escaping @Sendable (Data) -> Void) {
    self.finished = finished
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardOutput = output
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        try? handle.close()
        self?.update { $0.outputClosed = true }
      } else {
        self?.update { $0.data.append(chunk) }
      }
    }
    process.terminationHandler = { [weak self] _ in self?.update { $0.exited = true } }
    do {
      try process.run()
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      return nil
    }
  }

  public var processIdentifier: Int32 { process.processIdentifier }

  public func stop() {
    lock.withLock { stopped = true }
    if process.isRunning { process.terminate() }
  }

  private func update(_ change: (RexWaitProcess) -> Void) {
    let result: Data? = lock.withLock {
      change(self)
      guard outputClosed, exited, !stopped else { return nil }
      stopped = true
      return data
    }
    if let result { finished(result) }
  }
}

@MainActor
final class PaneWatches {
  static let maximumRetryDelay: TimeInterval = 5

  private struct Watch {
    var process: PaneWaitProcess?
    var generation: Int
    var failures: Int
  }

  private let launch: PaneWaitLauncher
  private let session: String
  private var watches: [String: Watch] = [:]
  private var generation = 0
  var onFinish: (_ block: String, _ generation: Int, _ output: Data) -> Void = { _, _, _ in }
  var retryDelay: (Int) -> TimeInterval = { failures in min(pow(2, Double(failures - 1)), PaneWatches.maximumRetryDelay)
  }

  init(session: String, launch: @escaping PaneWaitLauncher) {
    self.session = session
    self.launch = launch
  }

  var blocks: Set<String> { Set(watches.keys) }

  func start(_ block: String) {
    guard watches[block] == nil else { return }
    watches[block] = Watch(process: nil, generation: 0, failures: 0)
    run(block)
  }

  func retry(_ block: String, generation finished: Int) {
    guard var watch = watches[block], watch.generation == finished, watch.process == nil else { return }
    watch.failures += 1
    watch.process = nil
    generation += 1
    watch.generation = generation
    let expected = generation
    watches[block] = watch
    let delay = retryDelay(watch.failures)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.watches[block]?.generation == expected else { return }
        self.run(block)
      }
    }
  }

  func stop(_ block: String) {
    watches.removeValue(forKey: block)?.process?.stop()
  }

  func stopAll() {
    for block in watches.keys { stop(block) }
  }

  private func run(_ block: String) {
    generation += 1
    let expected = generation
    let finished: @Sendable (Data) -> Void = { output in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.finished(block, generation: expected, output: output) }
      }
    }
    let process = launch(RexEditorPane.waitArguments(block: block, session: session), finished)
    watches[block]?.process = process
    watches[block]?.generation = expected
    if process == nil { finished(Data()) }
  }

  private func finished(_ block: String, generation expected: Int, output: Data) {
    guard watches[block]?.generation == expected else { return }
    watches[block]?.process = nil
    onFinish(block, expected, output)
  }
}
