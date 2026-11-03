import Foundation

public final class GatedTerminalOutput: TerminalOutput {
  private let target: TerminalOutput
  private let lock = NSLock()
  private var open: Bool

  public init(_ target: TerminalOutput, isOpen: Bool = true) {
    self.target = target
    open = isOpen
  }

  public var isOpen: Bool {
    lock.lock()
    defer { lock.unlock() }
    return open
  }

  public func openGate() {
    lock.lock()
    defer { lock.unlock() }
    open = true
  }

  public func closeGate() {
    lock.lock()
    defer { lock.unlock() }
    open = false
  }

  public func write(_ text: String) {
    lock.lock()
    defer { lock.unlock() }
    guard open else { return }
    target.write(text)
  }

  public func writeBypassingGate(_ text: String) {
    lock.lock()
    defer { lock.unlock() }
    target.write(text)
  }
}
