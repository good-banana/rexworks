import MDViewerCore

public struct PaneSizeTracker: Sendable {
  public enum Action: Equatable, Sendable {
    case observe(PaneSize)
    case queryCellSize
  }

  public private(set) var inBandReports: Bool?
  public private(set) var cellSize: (width: Int, height: Int)?
  private var lastGrid: PaneSize?

  public init() {}

  public mutating func modeReport(_ report: ModeReport) -> [Action] {
    guard report.mode == 2048 else { return [] }
    inBandReports = (1...3).contains(report.state)
    guard inBandReports == false, let lastGrid else { return [] }
    return windowChanged(lastGrid)
  }

  public mutating func inBandReport(_ size: PaneSize) -> [Action] {
    inBandReports = true
    return [.observe(size)]
  }

  public mutating func cellSizeReport(width: Int, height: Int) -> [Action] {
    guard width > 0, height > 0 else { return [] }
    cellSize = (width, height)
    guard inBandReports != true, let lastGrid else { return [] }
    return [.observe(sized(lastGrid))]
  }

  public mutating func windowChanged(_ ioctl: PaneSize) -> [Action] {
    lastGrid = ioctl
    guard inBandReports != true else { return [] }
    return [.queryCellSize, .observe(sized(ioctl))]
  }

  private func sized(_ grid: PaneSize) -> PaneSize {
    guard let cellSize else { return grid }
    return PaneSize(
      columns: grid.columns, rows: grid.rows, pixelWidth: grid.columns * cellSize.width,
      pixelHeight: grid.rows * cellSize.height)
  }
}
