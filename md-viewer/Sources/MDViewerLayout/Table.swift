import CoreGraphics
import MDViewerDocument

struct PlacedCell {
  var row: Int
  var column: Int
  var rowSpan: Int
  var columnSpan: Int
  var node: CellNode
}

struct TableGrid {
  var cells: [PlacedCell]
  var columns: Int
  var rows: Int

  init(_ table: TableNode) {
    rows = table.rows.count
    var occupied: [[Bool]] = Array(repeating: [], count: rows)
    var placed: [PlacedCell] = []
    var columnCount = 0
    for (rowIndex, row) in table.rows.enumerated() {
      var column = 0
      for cell in row {
        while column < occupied[rowIndex].count, occupied[rowIndex][column] { column += 1 }
        let rowSpan = min(max(cell.rowSpan, 1), rows - rowIndex)
        let columnSpan = min(max(cell.columnSpan, 1), 1000)
        for spannedRow in rowIndex..<(rowIndex + rowSpan) {
          if occupied[spannedRow].count < column + columnSpan {
            occupied[spannedRow] += Array(repeating: false, count: column + columnSpan - occupied[spannedRow].count)
          }
          for spannedColumn in column..<(column + columnSpan) { occupied[spannedRow][spannedColumn] = true }
        }
        placed.append(
          PlacedCell(row: rowIndex, column: column, rowSpan: rowSpan, columnSpan: columnSpan, node: cell))
        column += columnSpan
        columnCount = max(columnCount, column)
      }
    }
    cells = placed
    columns = columnCount
  }
}

struct ColumnSizing: Equatable {
  var minimum: [CGFloat]
  var maximum: [CGFloat]

  func widths(available: CGFloat) -> [CGFloat] {
    let minimumTotal = minimum.reduce(0, +)
    let maximumTotal = maximum.reduce(0, +)
    if maximumTotal <= available { return maximum }
    if minimumTotal >= available || maximumTotal <= minimumTotal { return minimum }
    let ratio = (available - minimumTotal) / (maximumTotal - minimumTotal)
    return zip(minimum, maximum).map { $0 + ($1 - $0) * ratio }
  }
}

extension LayoutEngine {
  private var cellPadding: CGSize {
    CGSize(
      width: typography.pixels(em: typography.tableCellPadding.width),
      height: typography.pixels(em: typography.tableCellPadding.height))
  }

  func columnSizing(_ grid: TableGrid) -> ColumnSizing {
    var minimum = [CGFloat](repeating: 0, count: grid.columns)
    var maximum = [CGFloat](repeating: 0, count: grid.columns)
    let padding = cellPadding.width * 2
    let measured = grid.cells.map { intrinsic($0.node.children) }
    for (cell, size) in zip(grid.cells, measured) where cell.columnSpan == 1 {
      minimum[cell.column] = max(minimum[cell.column], size.min + padding)
      maximum[cell.column] = max(maximum[cell.column], size.max + padding)
    }
    for (cell, size) in zip(grid.cells, measured) where cell.columnSpan > 1 {
      let columns = cell.column..<(cell.column + cell.columnSpan)
      let currentMinimum = columns.map { minimum[$0] }.reduce(0, +)
      let currentMaximum = columns.map { maximum[$0] }.reduce(0, +)
      let extraMinimum = (size.min + padding - currentMinimum) / CGFloat(cell.columnSpan)
      let extraMaximum = (size.max + padding - currentMaximum) / CGFloat(cell.columnSpan)
      for column in columns {
        if extraMinimum > 0 { minimum[column] += extraMinimum }
        if extraMaximum > 0 { maximum[column] += extraMaximum }
      }
    }
    for column in 0..<grid.columns where maximum[column] < minimum[column] { maximum[column] = minimum[column] }
    return ColumnSizing(minimum: minimum, maximum: maximum)
  }

  mutating func table(
    _ id: BlockID, _ table: TableNode, x origin: CGFloat, width: CGFloat, y: inout CGFloat, alignment: TextAlignment?
  ) {
    let grid = TableGrid(table)
    guard grid.columns > 0 else { return }
    let widths = columnSizing(grid).widths(available: width)
    var columnX = [CGFloat](repeating: 0, count: grid.columns + 1)
    for column in 0..<grid.columns { columnX[column + 1] = columnX[column] + widths[column] }
    let tableWidth = columnX[grid.columns]
    let slack = max(width - tableWidth, 0)
    let x: CGFloat =
      switch alignment {
      case .center: origin + (slack / 2).rounded()
      case .right: origin + slack
      default: origin
      }
    let padding = cellPadding
    let start = out.mark
    let top = y

    var laidOut: [(cell: PlacedCell, start: LayoutBuilder.Mark, end: LayoutBuilder.Mark, height: CGFloat)] = []
    for cell in grid.cells {
      let cellStart = out.mark
      var cellY: CGFloat = 0
      let cellWidth = columnX[cell.column + cell.columnSpan] - columnX[cell.column]
      var context = LayoutContext()
      context.isTight = true
      context.alignment =
        switch cell.node.alignment {
        case .center: .center
        case .right: .right
        case .left: .left
        case .none: cell.node.isHeader ? .center : nil
        }
      container(
        cell.node.children, x: x + columnX[cell.column] + padding.width,
        width: max(cellWidth - padding.width * 2, 1), y: &cellY, context: context)
      laidOut.append((cell, cellStart, out.mark, cellY))
    }

    let emptyRow = typography.pixels(em: typography.bodyLineHeight * typography.tableScale) + padding.height * 2
    var rowHeights = [CGFloat](repeating: emptyRow, count: grid.rows)
    for entry in laidOut where entry.cell.rowSpan == 1 {
      rowHeights[entry.cell.row] = max(rowHeights[entry.cell.row], entry.height + padding.height * 2)
    }
    for entry in laidOut where entry.cell.rowSpan > 1 {
      let rows = entry.cell.row..<(entry.cell.row + entry.cell.rowSpan)
      let spanned = rows.map { rowHeights[$0] }.reduce(0, +)
      let needed = entry.height + padding.height * 2
      if needed > spanned { rowHeights[rows.upperBound - 1] += needed - spanned }
    }
    var rowY = [CGFloat](repeating: top, count: grid.rows + 1)
    for row in 0..<grid.rows { rowY[row + 1] = rowY[row] + rowHeights[row] }

    for entry in laidOut {
      let cell = entry.cell
      let spanHeight = rowY[cell.row + cell.rowSpan] - rowY[cell.row]
      let slack = max(spanHeight - padding.height * 2 - entry.height, 0)
      out.shift(from: entry.start, to: entry.end, dy: rowY[cell.row] + padding.height + (slack / 2).rounded())
    }

    var chrome: [Decoration] = []
    for row in 0..<grid.rows {
      let rect = CGRect(x: x, y: rowY[row], width: tableWidth, height: rowHeights[row])
      if row < table.headerRows {
        chrome.append(Decoration(rect: rect, kind: .tableHeaderFill, region: nil, cornerRadius: 0))
      } else if (row - table.headerRows) % 2 == 1 {
        chrome.append(Decoration(rect: rect, kind: .tableStripe, region: nil, cornerRadius: 0))
      }
    }
    for entry in laidOut {
      let cell = entry.cell
      let rect = CGRect(
        x: x + columnX[cell.column], y: rowY[cell.row],
        width: columnX[cell.column + cell.columnSpan] - columnX[cell.column],
        height: rowY[cell.row + cell.rowSpan] - rowY[cell.row])
      chrome.append(Decoration(rect: rect, kind: .tableCellBorder, region: nil, cornerRadius: 0))
    }
    out.decorations.insert(contentsOf: chrome, at: start.decorations)
    y = rowY[grid.rows]
    if tableWidth > width + 0.5 {
      out.assignRegion(id, since: start)
      out.regions.append(
        ScrollRegion(
          id: id, rect: CGRect(x: origin, y: top, width: width, height: y - top), contentWidth: tableWidth,
          offset: min(max(input.scrollOffsets[id] ?? 0, 0), tableWidth - width), kind: .table))
    }
  }

  func intrinsic(_ nodes: [Node]) -> (min: CGFloat, max: CGFloat) {
    var result: (min: CGFloat, max: CGFloat) = (0, 0)
    for node in nodes {
      let size = intrinsic(node)
      result = (Swift.max(result.min, size.min), Swift.max(result.max, size.max))
    }
    return result
  }

  private func intrinsic(_ node: Node) -> (min: CGFloat, max: CGFloat) {
    func inset(_ size: (min: CGFloat, max: CGFloat), _ amount: CGFloat) -> (min: CGFloat, max: CGFloat) {
      (size.min + amount, size.max + amount)
    }
    switch node {
    case .heading(_, _, _, let run), .paragraph(_, let run, _):
      return intrinsic(run)
    case .quote(_, let children):
      return inset(intrinsic(children), em(typography.barWidth + typography.blockquotePadding))
    case .alert(_, _, let title, let children):
      let inner = intrinsic(children)
      let titleWidth = em(typography.alertIconSize + typography.alertIconGap) + prepared.labels[title].width
      return inset(
        (Swift.max(inner.min, titleWidth), Swift.max(inner.max, titleWidth)),
        em(typography.barWidth + typography.alertPadding.width * 2))
    case .list(_, let list):
      return inset(intrinsic(list.items.flatMap(\.children)), em(typography.listIndent))
    case .code(_, let lines):
      var widest: CGFloat = 0
      for line in lines { widest = Swift.max(widest, lineWidth(line)) }
      let width = widest + em(typography.codePadding) * 2
      return (width, width)
    case .diagram(_, let code):
      let width = input.diagramSize(code).map { typography.pixels(cssPoints: $0.width) } ?? 0
      return (0, width)
    case .table(_, let table):
      let sizing = columnSizing(TableGrid(table))
      return (sizing.minimum.reduce(0, +), sizing.maximum.reduce(0, +))
    case .footnote(_, _, _, _, let children):
      return inset(intrinsic(children), em(typography.footnoteIndent))
    case .details(let id, let summary, let children):
      var size = inset(intrinsic(summary), em(typography.detailsMarkerWidth))
      if input.expandedDetails.contains(id) {
        let inner = intrinsic(children)
        size = (Swift.max(size.min, inner.min), Swift.max(size.max, inner.max))
      }
      return size
    case .division(_, _, let children):
      return intrinsic(children)
    case .rule:
      return (0, 0)
    case .frontMatter(_, let rows):
      let chrome =
        em(typography.frontMatterBarWidth + typography.frontMatterPadding.width * 2 + typography.frontMatterColumnGap)
      let keys = rows.map { intrinsic($0.key) }
      let values = rows.map { intrinsic($0.value) }
      return (
        chrome + (keys.map(\.min).max() ?? 0) + (values.map(\.min).max() ?? 0),
        chrome + (keys.map(\.max).max() ?? 0) + (values.map(\.max).max() ?? 0)
      )
    }
  }

  private func intrinsic(_ run: Run) -> (min: CGFloat, max: CGFloat) {
    var images: CGFloat = 0
    for word in run.words {
      if let image = word.image { images += imageSize(image, maxWidth: .greatestFiniteMagnitude).size.width }
    }
    return (run.minWidth, run.maxWidth + images)
  }
}
