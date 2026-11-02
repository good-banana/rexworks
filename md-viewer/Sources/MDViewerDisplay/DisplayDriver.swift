import Darwin
import Dispatch

public final class FileDescriptorOutput: TerminalOutput {
  public let descriptor: Int32

  public init(descriptor: Int32 = STDOUT_FILENO) {
    self.descriptor = descriptor
  }

  public func write(_ text: String) {
    var bytes = Array(text.utf8)[...]
    while !bytes.isEmpty {
      let written = bytes.withUnsafeBufferPointer { Darwin.write(descriptor, $0.baseAddress, $0.count) }
      if written < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        return
      }
      bytes = bytes.dropFirst(written)
    }
  }
}

public final class DisplayDriver {
  public let transport: DisplayTransport
  private let queue: DispatchQueue
  private let timer: DispatchSourceTimer
  private var armedFor: UInt64?

  public init(transport: DisplayTransport, queue: DispatchQueue = .main) {
    self.transport = transport
    self.queue = queue
    timer = DispatchSource.makeTimerSource(queue: queue)
    timer.setEventHandler { [weak self] in
      self?.armedFor = nil
      self?.kick()
    }
    timer.schedule(deadline: .distantFuture)
    timer.resume()
  }

  deinit {
    timer.cancel()
  }

  public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

  public func kick() {
    let now = Self.now()
    transport.pump(at: now)
    guard let wake = transport.nextWake(after: Self.now()) else { return }
    guard armedFor != wake else { return }
    armedFor = wake
    timer.schedule(deadline: DispatchTime(uptimeNanoseconds: max(wake, Self.now())))
  }
}
