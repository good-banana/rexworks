public struct ImageLedger: Equatable, Sendable {
  public private(set) var displayed: UInt32?
  public private(set) var pending: UInt32?
  public private(set) var live: Set<UInt32> = []
  var next: UInt32

  public init(firstID: UInt32) {
    next = firstID == 0 ? 1 : firstID
  }

  public static func firstID(processID: Int32) -> UInt32 {
    UInt32(truncatingIfNeeded: processID & 0x3fff) << 16 | 1
  }

  public mutating func allocate() -> UInt32 {
    var candidate = next
    while candidate == 0 || live.contains(candidate) || candidate >= FenceIDs.base {
      candidate = candidate == 0 || candidate >= FenceIDs.base ? 1 : candidate + 1
    }
    next = candidate + 1
    live.insert(candidate)
    pending = candidate
    return candidate
  }

  public mutating func confirm(_ id: UInt32) -> [UInt32] {
    guard live.contains(id) else { return [] }
    if pending == id { pending = nil }
    displayed = id
    let retired = live.subtracting([id]).subtracting(pending.map { [$0] } ?? []).sorted()
    live.subtract(retired)
    return retired
  }

  public mutating func discard(_ id: UInt32) {
    live.remove(id)
    if pending == id { pending = nil }
    if displayed == id { displayed = nil }
  }

  public mutating func removeAll() -> [UInt32] {
    defer {
      live = []
      pending = nil
      displayed = nil
    }
    return live.sorted()
  }
}

public struct FenceIDs: Equatable, Sendable {
  public static let base: UInt32 = 0x8000_0000

  private var next: UInt32 = base

  public init() {}

  public mutating func allocate() -> UInt32 {
    defer { next = next == UInt32.max ? Self.base : next + 1 }
    return next
  }
}
