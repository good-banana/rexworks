import CoreGraphics
import MDViewerLayout
import MDViewerMermaid

public struct DiagramContext: Hashable, Sendable {
  public var theme: MermaidTheme
  public var width: CGFloat
  public var scale: CGFloat

  public init(theme: MermaidTheme, pageWidth: CGFloat, typography: Typography) {
    self.theme = theme
    let margin = typography.pixels(em: typography.pageMarginSide)
    let column = max(pageWidth - margin * 2, typography.pixels(em: 4))
    scale = typography.scale
    width = column / scale
  }

  public func request(_ code: String) -> MermaidRequest {
    MermaidRequest(code: code, theme: theme, width: width, scale: scale)
  }
}

public enum DiagramPlan {
  public static func codes(in layout: PageLayout, visible: CGRect) -> [String] {
    var seen: Set<String> = []
    var ordered: [String] = []
    func add(_ code: String) {
      if seen.insert(code).inserted { ordered.append(code) }
    }
    for box in layout.images {
      guard case .diagram(let code) = box.content,
        layout.displayRect(box.rect, region: box.region).intersects(visible)
      else { continue }
      add(code)
    }
    let blocks = layout.prepared.codeBlocks.filter(\.value.isDiagram).sorted { $0.key < $1.key }
    for (_, block) in blocks { add(block.code) }
    return ordered
  }
}
