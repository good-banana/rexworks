import CoreGraphics
import Foundation

public struct History {
  public struct Entry: Equatable {
    public var file: URL
    public var offset: CGFloat

    public init(file: URL, offset: CGFloat) {
      self.file = file
      self.offset = offset
    }
  }

  private let limit: Int
  private var entries: [Entry] = []

  public init(limit: Int = 100) {
    self.limit = max(limit, 1)
  }

  public mutating func push(_ e: Entry) {
    entries.append(e)
    if entries.count > limit { entries.removeFirst(entries.count - limit) }
  }

  public mutating func pop() -> Entry? {
    entries.popLast()
  }
}
