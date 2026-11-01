import CoreGraphics

public struct TileSlice: Equatable, Sendable {
  public var index: Int
  public var source: CGRect
  public var destinationRow: Int
  public var rows: Int

  public init(index: Int, source: CGRect, destinationRow: Int, rows: Int) {
    self.index = index
    self.source = source
    self.destinationRow = destinationRow
    self.rows = rows
  }
}

public struct Viewport: Equatable, Sendable {
  public var pageHeight: CGFloat
  public var viewHeight: CGFloat
  public var tileHeight: CGFloat
  public var offset: CGFloat
  public var cellHeight: CGFloat

  public init(pageHeight: CGFloat, viewHeight: CGFloat, tileHeight: CGFloat, offset: CGFloat, cellHeight: CGFloat) {
    self.pageHeight = pageHeight
    self.viewHeight = viewHeight
    self.tileHeight = tileHeight
    self.offset = offset
    self.cellHeight = cellHeight
  }

  public var contentHeight: CGFloat {
    (pageHeight / cellHeight).rounded(.up) * cellHeight
  }

  public var maximumOffset: CGFloat {
    max(0, contentHeight - viewHeight)
  }

  public var tileCount: Int {
    tileHeight > 0 ? Int((contentHeight / tileHeight).rounded(.up)) : 0
  }

  public var fraction: CGFloat {
    maximumOffset > 0 ? offset / maximumOffset : 0
  }

  public var percent: Int {
    maximumOffset > 0 ? Int((fraction * 100).rounded()) : 100
  }

  public mutating func scroll(by delta: CGFloat) {
    scroll(to: offset + delta)
  }

  public mutating func scroll(to target: CGFloat) {
    let clamped = min(max(target, 0), maximumOffset)
    offset = min((clamped / cellHeight).rounded() * cellHeight, maximumOffset)
  }

  public mutating func scroll(toFraction value: CGFloat) {
    scroll(to: value * maximumOffset)
  }

  public mutating func reveal(top: CGFloat, bottom: CGFloat) {
    guard top < offset || bottom > offset + viewHeight else { return }
    scroll(to: top - viewHeight / 4)
  }

  public func tiles(coveringTop top: CGFloat, bottom: CGFloat) -> ClosedRange<Int> {
    let last = max(tileCount - 1, 0)
    func index(_ y: CGFloat) -> Int {
      tileHeight > 0 ? min(max(Int((y / tileHeight).rounded(.down)), 0), last) : 0
    }
    let first = index(top)
    return first...max(first, index(bottom))
  }

  public func visibleTiles() -> [TileSlice] {
    guard tileHeight > 0, cellHeight > 0 else { return [] }
    let bottom = min(offset + viewHeight, contentHeight)
    var slices: [TileSlice] = []
    var top = offset
    while top < bottom {
      let index = Int((top / tileHeight).rounded(.down))
      let tileTop = CGFloat(index) * tileHeight
      let height = min(tileTop + tileHeight, bottom) - top
      slices.append(
        TileSlice(
          index: index, source: CGRect(x: 0, y: top - tileTop, width: 0, height: height),
          destinationRow: Int(((top - offset) / cellHeight).rounded()),
          rows: Int((height / cellHeight).rounded())))
      top += height
    }
    return slices
  }
}
