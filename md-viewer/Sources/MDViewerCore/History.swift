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
  private var forwardEntries: [Entry] = []

  public init(limit: Int = 100) {
    self.limit = max(limit, 1)
  }

  public var canGoBack: Bool { !entries.isEmpty }
  public var canGoForward: Bool { !forwardEntries.isEmpty }

  public mutating func push(_ e: Entry) {
    entries.append(e)
    forwardEntries = []
    if entries.count > limit { entries.removeFirst(entries.count - limit) }
  }

  public mutating func pop() -> Entry? {
    entries.popLast()
  }

  public mutating func back(from current: Entry) -> Entry? {
    guard let entry = entries.popLast() else { return nil }
    forwardEntries.append(current)
    if forwardEntries.count > limit { forwardEntries.removeFirst(forwardEntries.count - limit) }
    return entry
  }

  public mutating func forward(from current: Entry) -> Entry? {
    guard let entry = forwardEntries.popLast() else { return nil }
    entries.append(current)
    if entries.count > limit { entries.removeFirst(entries.count - limit) }
    return entry
  }
}
