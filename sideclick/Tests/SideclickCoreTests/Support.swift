import Foundation
import SideclickCore

func fixture(_ name: String) throws -> Data {
  guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
    throw OpenError("missing fixture \(name)")
  }
  return try Data(contentsOf: url)
}

final class FakeRunner: CommandRunning, @unchecked Sendable {
  struct Failure: Error {}

  struct Call: Equatable {
    let executable: String
    let arguments: [String]
  }

  private let lock = NSLock()
  private var recorded: [Call] = []
  private let respond: @Sendable (String, [String]) throws -> CommandResult

  init(_ respond: @escaping @Sendable (String, [String]) throws -> CommandResult) {
    self.respond = respond
  }

  var calls: [Call] {
    lock.withLock { recorded }
  }

  func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
    lock.withLock { recorded.append(Call(executable: executable, arguments: arguments)) }
    return try respond(executable, arguments)
  }
}

func ok(_ text: String) -> CommandResult {
  CommandResult(status: 0, stdout: Data(text.utf8))
}

func ok(_ data: Data) -> CommandResult {
  CommandResult(status: 0, stdout: data)
}

final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool {
    lock.withLock { value }
  }

  func set() {
    lock.withLock { value = true }
  }
}

final class FakeClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 0)

  var now: @Sendable () -> Date {
    { self.lock.withLock { self.current } }
  }

  var advance: @Sendable (TimeInterval) -> Void {
    { interval in self.lock.withLock { self.current += interval } }
  }

  func advance(_ interval: TimeInterval) {
    lock.withLock { current += interval }
  }
}

struct ThrowingAfterSplitRunner {
  let fake: FakeRunner

  init(base: @escaping @Sendable (String, [String]) -> CommandResult, split: LockedFlag) {
    fake = FakeRunner { executable, arguments in
      if arguments.contains("run") { split.set() }
      if split.isSet, arguments.first == "ls" { throw FakeRunner.Failure() }
      return base(executable, arguments)
    }
  }
}
