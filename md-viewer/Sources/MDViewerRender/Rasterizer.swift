import CoreGraphics
import CoreText
import CryptoKit
import MDViewerCore
import MDViewerLayout

public struct RenderAssets: Sendable {
  public var image: @Sendable (String) -> CGImage?
  public var diagram: @Sendable (String) -> CGImage?

  public init(
    image: @escaping @Sendable (String) -> CGImage? = { _ in nil },
    diagram: @escaping @Sendable (String) -> CGImage? = { _ in nil }
  ) {
    self.image = image
    self.diagram = diagram
  }
}

public enum FocusRing: Hashable, Sendable {
  case text(Range<Int>)
  case codeBlock(BlockID)
  case region(BlockID)
  case target(HitTarget)
}

public struct CopyButtonOverlay: Hashable, Sendable {
  public var block: BlockID
  public var copied: Bool

  public init(block: BlockID, copied: Bool = false) {
    self.block = block
    self.copied = copied
  }
}

public struct RenderOverlay: Sendable {
  public var selection: Range<Int>?
  public var findMatches: [FindMatch]
  public var currentMatch: Int?
  public var focus: FocusRing?
  public var copyButton: CopyButtonOverlay?

  public init(
    selection: Range<Int>? = nil, findMatches: [FindMatch] = [], currentMatch: Int? = nil, focus: FocusRing? = nil,
    copyButton: CopyButtonOverlay? = nil
  ) {
    self.selection = selection
    self.findMatches = findMatches
    self.currentMatch = currentMatch
    self.focus = focus
    self.copyButton = copyButton
  }
}

public struct Rasterizer: @unchecked Sendable {
  public private(set) var layout: PageLayout
  public let palette: RenderPalette
  public var assets: RenderAssets
  public var highlights: [BlockID: HighlightResult]
  let index: SceneIndex

  public init(
    layout: PageLayout, palette: RenderPalette, assets: RenderAssets = RenderAssets(),
    highlights: [BlockID: HighlightResult] = [:]
  ) {
    self.layout = layout
    self.palette = palette
    self.assets = assets
    self.highlights = highlights
    index = SceneIndex(layout)
  }

  public mutating func setScrollOffset(_ offset: CGFloat, for region: BlockID) {
    layout = layout.settingScrollOffset(offset, for: region)
  }

  public func render(_ rect: CGRect, scale: CGFloat = 1, overlay: RenderOverlay = RenderOverlay()) -> RasterBitmap? {
    guard Self.isDrawable(rect), scale.isFinite, scale > 0,
      Self.isDrawable(CGRect(x: 0, y: 0, width: rect.width * scale, height: rect.height * scale)),
      let bitmap = RasterBitmap(width: Self.pixels(rect.width * scale), height: Self.pixels(rect.height * scale))
    else { return nil }
    draw(rect, into: bitmap, scale: scale, overlay: overlay)
    return bitmap
  }

  public func draw(
    _ rect: CGRect, into bitmap: RasterBitmap, at origin: CGPoint = .zero, scale: CGFloat = 1,
    overlay: RenderOverlay = RenderOverlay()
  ) {
    guard Self.isDrawable(rect), scale.isFinite, scale > 0, origin.x.isFinite, origin.y.isFinite else { return }
    let context = bitmap.context
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: 0, y: CGFloat(bitmap.height))
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: origin.x, y: origin.y)
    context.clip(to: CGRect(x: 0, y: 0, width: rect.width * scale, height: rect.height * scale))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -rect.minX, y: -rect.minY)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    let painter = Painter(rasterizer: self, context: context, visible: rect, overlay: overlay)
    painter.paint()
  }

  public func renderViewport(
    scrollY: CGFloat, size: CGSize, overlay: RenderOverlay = RenderOverlay(), status: StatusBarContent? = nil,
    statusBarHeight: CGFloat = 0
  ) -> RasterBitmap? {
    guard Self.isDrawable(CGRect(origin: .zero, size: size)), scrollY.isFinite,
      let bitmap = RasterBitmap(width: Self.pixels(size.width), height: Self.pixels(size.height))
    else { return nil }
    let barHeight = status == nil || !statusBarHeight.isFinite ? 0 : min(max(statusBarHeight, 0), size.height)
    let documentHeight = size.height - barHeight
    if documentHeight > 0 {
      draw(CGRect(x: 0, y: scrollY, width: size.width, height: documentHeight), into: bitmap, overlay: overlay)
    }
    if let status, barHeight > 0 {
      StatusBar(palette: palette, backingScale: layout.prepared.typography.backingScale).draw(
        status, in: CGRect(x: 0, y: documentHeight, width: size.width, height: barHeight), bitmap: bitmap)
    }
    return bitmap
  }

  static let maximumPixels: CGFloat = 32_768

  static func pixels(_ value: CGFloat) -> Int { max(Int(value.rounded(.up)), 1) }

  static func isDrawable(_ rect: CGRect) -> Bool {
    [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width >= 0.5
      && rect.height >= 0.5 && rect.width <= maximumPixels && rect.height <= maximumPixels
  }
}

final class SceneIndex: @unchecked Sendable {
  struct CodeLine {
    var range: Range<Int>
    var block: BlockID
    var line: Int
  }

  struct CellEdges {
    var right: Bool
    var bottom: Bool
  }

  let codeLines: [CodeLine]
  let codeBlockRects: [BlockID: CGRect]
  let copyButtons: [BlockID: CGRect]
  let cellEdges: [Int: CellEdges]
  let frontMatterBoxes: [Decoration]
  let codeDigests: [BlockID: SHA256.Digest]
  let regionFills: [BlockID: [Decoration]]

  init(_ layout: PageLayout) {
    var lines: [CodeLine] = []
    var digests: [BlockID: SHA256.Digest] = [:]
    for (id, block) in layout.prepared.codeBlocks where !block.isDiagram {
      digests[id] = SyntaxHighlighter.digest(block.code)
      for (line, range) in block.lineRanges.enumerated() where !range.isEmpty {
        lines.append(CodeLine(range: range, block: id, line: line))
      }
    }
    codeDigests = digests
    codeLines = lines.sorted { $0.range.lowerBound < $1.range.lowerBound }

    var buttons: [BlockID: CGRect] = [:]
    for area in layout.targets {
      if case .copyCode(let id, _) = area.target { buttons[id] = area.rect }
    }
    copyButtons = buttons
    let backgrounds = layout.decorations.filter { $0.kind == .codeBlockBackground }.map(\.rect)
    var blockRects: [BlockID: CGRect] = [:]
    for (id, button) in buttons {
      let center = CGPoint(x: button.midX, y: button.midY)
      if let box = backgrounds.first(where: { $0.contains(center) && $0.minY <= button.minY }) {
        blockRects[id] = box
      }
    }
    codeBlockRects = blockRects

    var edges: [Int: CellEdges] = [:]
    var groupStart: Int?
    let decorations = layout.decorations
    func closeGroup(_ end: Int) {
      guard let start = groupStart else { return }
      let maxX = decorations[start..<end].map(\.rect.maxX).max() ?? 0
      let maxY = decorations[start..<end].map(\.rect.maxY).max() ?? 0
      for index in start..<end {
        let rect = decorations[index].rect
        edges[index] = CellEdges(right: abs(rect.maxX - maxX) < 0.5, bottom: abs(rect.maxY - maxY) < 0.5)
      }
      groupStart = nil
    }
    var groupBottom: CGFloat = 0
    for (index, decoration) in decorations.enumerated() {
      if decoration.kind == .tableCellBorder {
        if groupStart != nil, decoration.rect.minY > groupBottom + 0.5 { closeGroup(index) }
        if groupStart == nil {
          groupStart = index
          groupBottom = decoration.rect.maxY
        }
        groupBottom = max(groupBottom, decoration.rect.maxY)
      } else {
        closeGroup(index)
      }
    }
    closeGroup(decorations.count)
    cellEdges = edges
    frontMatterBoxes = decorations.filter { $0.kind == .frontMatterBackground }
    var fills: [BlockID: [Decoration]] = [:]
    for decoration in decorations where decoration.kind == .tableHeaderFill || decoration.kind == .tableStripe {
      if let region = decoration.region { fills[region, default: []].append(decoration) }
    }
    regionFills = fills
  }

  func codeLine(containing offset: Int) -> CodeLine? {
    var low = 0
    var high = codeLines.count
    while low < high {
      let mid = (low + high) / 2
      if codeLines[mid].range.lowerBound <= offset { low = mid + 1 } else { high = mid }
    }
    guard low > 0 else { return nil }
    let candidate = codeLines[low - 1]
    return candidate.range.contains(offset) ? candidate : nil
  }
}
