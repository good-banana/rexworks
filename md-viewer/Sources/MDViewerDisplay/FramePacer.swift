public struct FramePacer: Equatable, Sendable {
  public struct InFlight: Equatable, Sendable {
    public var fence: UInt32
    public var sentAt: UInt64
    public var stagedThrough: UInt64?
  }

  public static let sixtyHertz: UInt64 = 16_666_667
  public static let defaultFenceTimeout: UInt64 = 500_000_000

  public let minimumInterval: UInt64
  public let fenceTimeout: UInt64
  public private(set) var inFlight: InFlight?
  public private(set) var lastSent: UInt64?

  public init(minimumInterval: UInt64 = Self.sixtyHertz, fenceTimeout: UInt64 = Self.defaultFenceTimeout) {
    self.minimumInterval = minimumInterval
    self.fenceTimeout = fenceTimeout
  }

  public func earliestSend(after now: UInt64) -> UInt64 {
    if let inFlight { return max(inFlight.sentAt + fenceTimeout, now) }
    guard let lastSent else { return now }
    return max(lastSent + minimumInterval, now)
  }

  public func canSend(at now: UInt64) -> Bool {
    inFlight == nil && earliestSend(after: now) <= now
  }

  public mutating func sent(fence: UInt32, stagedThrough: UInt64?, at now: UInt64) {
    precondition(inFlight == nil, "a frame is already in flight")
    inFlight = InFlight(fence: fence, sentAt: now, stagedThrough: stagedThrough)
    lastSent = now
  }

  public mutating func acknowledge(_ fence: UInt32) -> InFlight? {
    guard let inFlight, inFlight.fence == fence else { return nil }
    self.inFlight = nil
    return inFlight
  }

  public mutating func expire(at now: UInt64) -> InFlight? {
    guard let inFlight, now >= inFlight.sentAt + fenceTimeout else { return nil }
    self.inFlight = nil
    return inFlight
  }
}
