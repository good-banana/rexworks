import CoreGraphics
import MDViewerCore
import MDViewerRender

public struct PixelRect: Hashable, Sendable, CustomStringConvertible {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public init(enclosing rect: CGRect) {
    let minX = Int(rect.minX.rounded(.down))
    let minY = Int(rect.minY.rounded(.down))
    self.init(
      x: minX, y: minY, width: Int(rect.maxX.rounded(.up)) - minX, height: Int(rect.maxY.rounded(.up)) - minY)
  }

  public var maxX: Int { x + width }
  public var maxY: Int { y + height }
  public var area: Int { width * height }
  public var isEmpty: Bool { width <= 0 || height <= 0 }
  public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
  public var description: String { "\(x),\(y) \(width)x\(height)" }

  public func intersection(_ other: PixelRect) -> PixelRect? {
    let minX = max(x, other.x)
    let minY = max(y, other.y)
    let result = PixelRect(x: minX, y: minY, width: min(maxX, other.maxX) - minX, height: min(maxY, other.maxY) - minY)
    return result.isEmpty ? nil : result
  }

  public func union(_ other: PixelRect) -> PixelRect {
    let minX = min(x, other.x)
    let minY = min(y, other.y)
    return PixelRect(x: minX, y: minY, width: max(maxX, other.maxX) - minX, height: max(maxY, other.maxY) - minY)
  }

  public func subtracting(_ other: PixelRect) -> [PixelRect] {
    guard let overlap = intersection(other) else { return isEmpty ? [] : [self] }
    return [
      PixelRect(x: x, y: y, width: width, height: overlap.y - y),
      PixelRect(x: x, y: overlap.maxY, width: width, height: maxY - overlap.maxY),
      PixelRect(x: x, y: overlap.y, width: overlap.x - x, height: overlap.height),
      PixelRect(x: overlap.maxX, y: overlap.y, width: maxX - overlap.maxX, height: overlap.height),
    ].filter { !$0.isEmpty }
  }

  public func touches(_ other: PixelRect) -> Bool {
    x <= other.maxX && other.x <= maxX && y <= other.maxY && other.y <= maxY
  }
}

public struct CellPosition: Hashable, Sendable {
  public var column: Int
  public var row: Int

  public init(column: Int, row: Int) {
    self.column = column
    self.row = row
  }
}

public struct DisplayViewport: Equatable, Sendable {
  public let size: PaneSize
  public let statusRows: Int
  public private(set) var pageHeight: CGFloat
  public private(set) var offset: CGFloat

  public init(size: PaneSize, statusRows: Int, pageHeight: CGFloat, offset: CGFloat = 0) {
    self.size = size
    self.statusRows = min(max(statusRows, 0), max(size.rows - 1, 0))
    self.pageHeight = pageHeight.isFinite ? max(pageHeight, 0) : 0
    self.offset = 0
    scroll(to: offset)
  }

  public init(size: PaneSize, backingScale: CGFloat, pageHeight: CGFloat, offset: CGFloat = 0, statusBar: Bool = true) {
    let cell = CGFloat(size.rows > 0 ? size.pixelHeight / size.rows : 0)
    let rows =
      statusBar && cell > 0
      ? Int((StatusBar.height(cellPixelHeight: cell, backingScale: backingScale) / cell).rounded()) : 0
    self.init(size: size, statusRows: rows, pageHeight: pageHeight, offset: offset)
  }

  public var cellWidth: Int { size.columns > 0 ? size.pixelWidth / size.columns : 0 }
  public var cellHeight: Int { size.rows > 0 ? size.pixelHeight / size.rows : 0 }
  public var frameWidth: Int { size.columns * cellWidth }
  public var frameHeight: Int { size.rows * cellHeight }
  public var contentRows: Int { size.rows - statusRows }
  public var contentHeight: Int { contentRows * cellHeight }
  public var statusBarHeight: Int { statusRows * cellHeight }
  public var isDrawable: Bool { cellWidth > 0 && cellHeight > 0 && contentRows > 0 }
  public var frameRect: PixelRect { PixelRect(x: 0, y: 0, width: frameWidth, height: frameHeight) }
  public var contentRect: PixelRect { PixelRect(x: 0, y: 0, width: frameWidth, height: contentHeight) }
  public var statusBarRect: PixelRect {
    PixelRect(x: 0, y: contentHeight, width: frameWidth, height: statusBarHeight)
  }

  public var maximumOffset: CGFloat {
    guard cellHeight > 0 else { return 0 }
    let overflow = pageHeight - CGFloat(contentHeight)
    return overflow > 0 ? (overflow / CGFloat(cellHeight)).rounded(.up) * CGFloat(cellHeight) : 0
  }

  public var visiblePageRect: CGRect {
    CGRect(x: 0, y: offset, width: CGFloat(frameWidth), height: CGFloat(contentHeight))
  }

  public var progress: (start: CGFloat, fraction: CGFloat) {
    guard pageHeight > 0 else { return (0, 1) }
    return (offset / pageHeight, min(CGFloat(contentHeight) / pageHeight, 1))
  }

  @discardableResult
  public mutating func scroll(to target: CGFloat) -> Bool {
    let previous = offset
    let clamped = target.isFinite ? min(max(target, 0), maximumOffset) : (target > 0 ? maximumOffset : 0)
    offset = cellHeight > 0 ? (clamped / CGFloat(cellHeight)).rounded() * CGFloat(cellHeight) : 0
    offset = min(offset, maximumOffset)
    return offset != previous
  }

  @discardableResult
  public mutating func scroll(by delta: CGFloat) -> Bool {
    scroll(to: offset + delta)
  }

  @discardableResult
  public mutating func scroll(rows: Int) -> Bool {
    scroll(by: CGFloat(rows * cellHeight))
  }

  public mutating func setPageHeight(_ height: CGFloat) {
    pageHeight = height.isFinite ? max(height, 0) : 0
    scroll(to: offset)
  }

  public func panePoint(fromPage point: CGPoint) -> CGPoint {
    CGPoint(x: point.x, y: point.y - offset)
  }

  public func pagePoint(fromPane point: CGPoint) -> CGPoint? {
    guard point.x >= 0, point.y >= 0, point.x < CGFloat(frameWidth), point.y < CGFloat(contentHeight) else {
      return nil
    }
    return CGPoint(x: point.x, y: point.y + offset)
  }

  public func paneRect(fromPage rect: CGRect) -> PixelRect? {
    PixelRect(enclosing: rect.offsetBy(dx: 0, dy: -offset)).intersection(contentRect)
  }

  public func pageRect(fromPane rect: PixelRect) -> CGRect {
    rect.cgRect.offsetBy(dx: 0, dy: offset)
  }

  public func cell(atPane point: CGPoint) -> CellPosition? {
    guard cellWidth > 0, cellHeight > 0, point.x >= 0, point.y >= 0 else { return nil }
    let column = Int(point.x) / cellWidth
    let row = Int(point.y) / cellHeight
    guard column < size.columns, row < size.rows else { return nil }
    return CellPosition(column: column, row: row)
  }

  public func paneRect(of cell: CellPosition) -> PixelRect {
    PixelRect(x: cell.column * cellWidth, y: cell.row * cellHeight, width: cellWidth, height: cellHeight)
  }

  public func pagePoint(fromCell cell: CellPosition) -> CGPoint? {
    pagePoint(fromPane: CGPoint(x: cell.column * cellWidth, y: cell.row * cellHeight))
  }
}
