import CoreGraphics
import CoreText
import MDViewerDocument

public struct BlockID: Hashable, Comparable, Sendable, CustomStringConvertible {
  public let rawValue: Int

  public init(_ rawValue: Int) { self.rawValue = rawValue }

  public static func < (lhs: BlockID, rhs: BlockID) -> Bool { lhs.rawValue < rhs.rawValue }

  public var description: String { "#\(rawValue)" }
}

public enum TextColorRole: Hashable, Sendable {
  case text, muted, heading, link, inlineCode, code
  case alertTitle(AlertKind)
}

public struct TextDecorations: OptionSet, Hashable, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let underline = TextDecorations(rawValue: 1)
  public static let strikethrough = TextDecorations(rawValue: 2)
  public static let dottedUnderline = TextDecorations(rawValue: 4)
}

public enum InlineBoxKind: Hashable, Sendable {
  case code, keyboard, mark
}

public struct TextStyle: Hashable, Sendable {
  public var color: TextColorRole
  public var decorations: TextDecorations
  public var box: InlineBoxKind?
  public var link: String?
}

public struct ShapedSegment: @unchecked Sendable {
  public let range: Range<Int>
  public let line: CTLine
  public let lineStart: Int
  public let style: TextStyle
  public let width: CGFloat
  public let trailingWhitespace: CGFloat
  public let ascent: CGFloat
  public let descent: CGFloat
  public let fontSize: CGFloat
  public let baselineShift: CGFloat
  let above: CGFloat
  let below: CGFloat
  let leadingPad: CGFloat
  let trailingPad: CGFloat
  let boxVerticalPad: CGFloat
  let breakAfter: Bool
  let boxGroup: Int?
  let affectsLineHeight: Bool
  public let bidiLevel: Int
  public let drawOffset: CGFloat

  public var isRightToLeft: Bool { bidiLevel % 2 == 1 }

  var advance: CGFloat { leadingPad + width + trailingPad }
  var visibleAdvance: CGFloat { leadingPad + width - trailingWhitespace + trailingPad }

  public func offset(at globalIndex: Int) -> CGFloat {
    let local = min(max(globalIndex, range.lowerBound), range.upperBound) - range.lowerBound
    return CTLineGetOffsetForStringIndex(line, lineStart + local, nil)
  }

  func caretOffsets() -> [CGFloat] {
    let count = range.count
    var carets = [CGFloat](repeating: .nan, count: count + 1)
    var trailing = [CGFloat](repeating: .nan, count: count)
    CTLineEnumerateCaretOffsets(line) { offset, index, leadingEdge, _ in
      let local = index - lineStart
      guard local >= 0, local < count else { return }
      if leadingEdge {
        if carets[local].isNaN { carets[local] = offset }
      } else if trailing[local].isNaN {
        trailing[local] = offset
      }
    }
    if count > 0 { carets[count] = trailing[count - 1].isNaN ? width : trailing[count - 1] }
    var previous: CGFloat = 0
    for index in carets.indices {
      if carets[index].isNaN { carets[index] = previous }
      previous = carets[index]
    }
    return carets
  }

  public func span(from lower: Int, to upper: Int) -> ClosedRange<CGFloat>? {
    let start = lineStart + min(max(lower, range.lowerBound), range.upperBound) - range.lowerBound
    let end = lineStart + min(max(upper, range.lowerBound), range.upperBound) - range.lowerBound
    guard start < end else { return nil }
    var low = CGFloat.infinity
    var high = -CGFloat.infinity
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      var indices = [CFIndex](repeating: 0, count: count)
      var positions = [CGPoint](repeating: .zero, count: count)
      var advances = [CGSize](repeating: .zero, count: count)
      let all = CFRange(location: 0, length: count)
      CTRunGetStringIndices(run, all, &indices)
      CTRunGetPositions(run, all, &positions)
      CTRunGetAdvances(run, all, &advances)
      for glyph in 0..<count where indices[glyph] >= start && indices[glyph] < end {
        low = min(low, positions[glyph].x)
        high = max(high, positions[glyph].x + advances[glyph].width)
      }
    }
    return low <= high ? low...high : nil
  }

  public func index(at x: CGFloat) -> Int {
    let index = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
    guard index != kCFNotFound else { return range.lowerBound }
    return min(max(index - lineStart, 0), range.count) + range.lowerBound
  }
}

public enum LabelRole: Hashable, Sendable {
  case listMarker
  case alertTitle(AlertKind)
}

public struct ShapedLabel: @unchecked Sendable {
  public let text: String
  public let line: CTLine
  public let width: CGFloat
  public let ascent: CGFloat
  public let descent: CGFloat
  public let role: LabelRole
  public let color: TextColorRole
}

public enum TextUnitKind: Hashable, Sendable {
  case inline, codeLine, tableCell, frontMatter, diagram
}

public struct TextUnit: Hashable, Sendable {
  public var range: Range<Int>
  public var block: BlockID
  public var kind: TextUnitKind
  public var source: SourceRange
}

public struct TextPosition: Hashable, Sendable {
  public var offset: Int
  public var block: BlockID
}

public struct TextFragment: Hashable, Sendable {
  public var segment: Int
  public var range: Range<Int>
  public var origin: CGPoint
  public var minX: CGFloat
  public var maxX: CGFloat
  public var lineTop: CGFloat
  public var lineBottom: CGFloat
  public var region: BlockID?
  public var isClipped: Bool
}

public enum DecorationKind: Hashable, Sendable {
  case inlineBox(InlineBoxKind)
  case codeBlockBackground
  case headingRule
  case thematicBreak
  case blockquoteBar
  case alertBar(AlertKind)
  case alertIcon(AlertKind)
  case tableHeaderFill
  case tableStripe
  case tableCellBorder
  case frontMatterBackground
  case frontMatterBar
  case taskBox(checked: Bool)
  case disclosure(expanded: Bool)
  case footnoteSeparator
  case copyButton
}

public struct Decoration: Hashable, Sendable {
  public var rect: CGRect
  public var kind: DecorationKind
  public var region: BlockID?
  public var cornerRadius: CGFloat
}

public struct PlacedLabel: Hashable, Sendable {
  public var label: Int
  public var origin: CGPoint
  public var region: BlockID?
}

public enum ImageContent: Hashable, Sendable {
  case image(source: String)
  case diagram(code: String)
}

public struct ImageBox: Hashable, Sendable {
  public var rect: CGRect
  public var content: ImageContent
  public var alt: String
  public var link: String?
  public var hasIntrinsicSize: Bool
  public var region: BlockID?
  public var block: BlockID
}

public enum HitTarget: Hashable, Sendable {
  case link(String)
  case detailsToggle(BlockID)
  case copyCode(BlockID, language: String?)
  case task(BlockID, checked: Bool)
}

public struct TargetArea: Hashable, Sendable {
  public var rect: CGRect
  public var target: HitTarget
  public var region: BlockID?
}

public enum ScrollRegionKind: Hashable, Sendable {
  case codeBlock(language: String?)
  case table
}

public struct ScrollRegion: Hashable, Sendable {
  public var id: BlockID
  public var rect: CGRect
  public var contentWidth: CGFloat
  public var offset: CGFloat
  public var kind: ScrollRegionKind

  public var maxOffset: CGFloat { max(0, contentWidth - rect.width) }
}

public struct HighlightRect: Hashable, Sendable {
  public var rect: CGRect
  public var region: BlockID?
}

public struct FindMatch: Hashable, Sendable {
  public var range: Range<Int>
  public var rects: [HighlightRect]

  public init(range: Range<Int>, rects: [HighlightRect]) {
    self.range = range
    self.rects = rects
  }
}

public struct AnchorPosition: Hashable, Sendable {
  public var y: CGFloat
  public var collapsedDetails: [BlockID]
}

public struct HitResult: Hashable, Sendable {
  public var position: TextPosition?
  public var target: HitTarget?
  public var region: BlockID?
}

public struct LayoutInput: Sendable {
  public var width: CGFloat
  public var expandedDetails: Set<BlockID>
  public var prefersDark: Bool
  public var scrollOffsets: [BlockID: CGFloat]
  public var imageSize: @Sendable (String) -> CGSize?
  public var diagramSize: @Sendable (String) -> CGSize?

  public init(
    width: CGFloat, expandedDetails: Set<BlockID> = [], prefersDark: Bool = false,
    scrollOffsets: [BlockID: CGFloat] = [:], imageSize: @escaping @Sendable (String) -> CGSize? = { _ in nil },
    diagramSize: @escaping @Sendable (String) -> CGSize? = { _ in nil }
  ) {
    self.width = width
    self.expandedDetails = expandedDetails
    self.prefersDark = prefersDark
    self.scrollOffsets = scrollOffsets
    self.imageSize = imageSize
    self.diagramSize = diagramSize
  }
}

extension SourceRange {
  public var isEmpty: Bool { end < start }
}
