import Foundation

public final class GatedTerminalOutput: TerminalOutput {
  private let target: TerminalOutput
  private let stateLock = NSLock()
  private let writeLock = NSLock()
  private var open: Bool

  public init(_ target: TerminalOutput, isOpen: Bool = true) {
    self.target = target
    open = isOpen
  }

  public var isOpen: Bool {
    stateLock.withLock { open }
  }

  public func openGate() {
    stateLock.withLock { open = true }
  }

  public func closeGate() {
    stateLock.withLock { open = false }
  }

  public func write(_ text: String) {
    writeLock.withLock {
      guard isOpen else { return }
      target.write(text)
    }
  }

  public func writeBypassingGate(_ text: String) {
    writeLock.withLock { target.write(text) }
  }
}
