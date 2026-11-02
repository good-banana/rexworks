import MDViewerCore

public struct ResizeDebouncer: Equatable, Sendable {
  public enum Action: Equatable, Sendable {
    case hold
    case settle(PaneSize)
  }

  public static let defaultSettleNanoseconds: UInt64 = 80_000_000

  public let settleNanoseconds: UInt64
  public private(set) var displayed: PaneSize
  public private(set) var pending: PaneSize?
  public private(set) var deadline: UInt64?

  public init(displayed: PaneSize, settleNanoseconds: UInt64 = Self.defaultSettleNanoseconds) {
    self.displayed = displayed
    self.settleNanoseconds = settleNanoseconds
  }

  public var isHolding: Bool { deadline != nil }

  public mutating func observe(_ size: PaneSize, at now: UInt64) -> Action? {
    if deadline == nil, size == displayed { return nil }
    if let pending, size == pending, deadline != nil { return nil }
    let wasHolding = isHolding
    pending = size
    deadline = now + settleNanoseconds
    return wasHolding ? nil : .hold
  }

  public mutating func reset(displayed size: PaneSize) {
    displayed = size
    pending = nil
    deadline = nil
  }

  public mutating func fire(at now: UInt64) -> Action? {
    guard let deadline, now >= deadline, let pending else { return nil }
    self.deadline = nil
    self.pending = nil
    displayed = pending
    return .settle(pending)
  }
}
