import Darwin
import Dispatch
import MDViewerCore

public final class FileDescriptorOutput: TerminalOutput {
  public static let pollTimeoutMilliseconds: Int32 = 1_000

  public let descriptor: Int32
  var systemWrite: (Int32, UnsafeRawPointer?, Int) -> Int = { Darwin.write($0, $1, $2) }
  var waitWritable: (Int32) -> Bool = { descriptor in
    var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    return poll(&request, 1, FileDescriptorOutput.pollTimeoutMilliseconds) > 0
  }

  public init(descriptor: Int32 = STDOUT_FILENO) {
    self.descriptor = descriptor
  }

  public func write(_ text: String) {
    let bytes = Array(text.utf8)
    let written = send(bytes)
    if written > 0, written < bytes.count {
      _ = send(Array("\u{1b}\\".utf8))
    }
  }

  private func send(_ bytes: [UInt8]) -> Int {
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...].withUnsafeBytes { systemWrite(descriptor, $0.baseAddress, $0.count) }
      if written >= 0 {
        offset += written
        continue
      }
      switch errno {
      case EINTR: continue
      case EAGAIN: if waitWritable(descriptor) { continue } else { return offset }
      default: return offset
      }
    }
    return offset
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

  public func handle(_ response: GraphicsResponse) {
    transport.handle(response, at: Self.now())
    kick()
  }

  public func observe(_ size: PaneSize) {
    transport.observe(size, at: Self.now())
    kick()
  }

  public func kick() {
    transport.pump(at: Self.now())
    guard let wake = transport.nextWake(after: Self.now()) else { return }
    guard armedFor != wake else { return }
    armedFor = wake
    timer.schedule(deadline: DispatchTime(uptimeNanoseconds: max(wake, Self.now())))
  }
}
