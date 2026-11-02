public enum FramePlan: Equatable, Sendable {
  case none
  case full
  case patches([PixelRect])
  case scroll(Int, [PixelRect])
}

public struct FrameDamage: Equatable, Sendable {
  public static let fullFrameThreshold = 0.4
  public static let maximumPatches = 8

  public private(set) var needsFullFrame = false
  public private(set) var rects: [PixelRect] = []
  public private(set) var scrollShift = 0

  public init() {}

  public var isEmpty: Bool { !needsFullFrame && rects.isEmpty && scrollShift == 0 }

  public mutating func invalidateAll() {
    needsFullFrame = true
    rects = []
    scrollShift = 0
  }

  public mutating func invalidate(_ rect: PixelRect) {
    guard !needsFullFrame, !rect.isEmpty else { return }
    var merged = rect
    var index = 0
    while index < rects.count {
      if rects[index].touches(merged) {
        merged = merged.union(rects.remove(at: index))
        index = 0
      } else {
        index += 1
      }
    }
    rects.append(merged)
    if rects.count > Self.maximumPatches {
      rects = [rects.dropFirst().reduce(rects[0]) { $0.union($1) }]
    }
  }

  public mutating func scroll(by delta: Int, content: PixelRect, statusBar: PixelRect) {
    guard !needsFullFrame, delta != 0 else { return }
    scrollShift += delta
    guard abs(scrollShift) < content.height else { return invalidateAll() }
    let previous = rects
    rects = []
    for rect in previous {
      if let moved = rect.intersection(content).flatMap({
        PixelRect(x: $0.x, y: $0.y - delta, width: $0.width, height: $0.height).intersection(content)
      }) {
        invalidate(moved)
      }
      for outside in rect.subtracting(content) { invalidate(outside) }
    }
    let exposed =
      delta > 0
      ? PixelRect(x: content.x, y: content.maxY - delta, width: content.width, height: delta)
      : PixelRect(x: content.x, y: content.y, width: content.width, height: -delta)
    invalidate(exposed)
    invalidate(statusBar)
  }

  public mutating func reset() {
    needsFullFrame = false
    rects = []
    scrollShift = 0
  }

  public func plan(in frame: PixelRect) -> FramePlan {
    if needsFullFrame { return .full }
    let clipped = rects.compactMap { $0.intersection(frame) }
    let area = clipped.reduce(0) { $0 + $1.area }
    if Double(area) > Double(frame.area) * Self.fullFrameThreshold { return .full }
    if scrollShift != 0 { return .scroll(scrollShift, clipped) }
    return clipped.isEmpty ? .none : .patches(clipped)
  }
}
