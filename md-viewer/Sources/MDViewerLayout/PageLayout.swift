import CoreGraphics
import Foundation
import MDViewerDocument

public struct PageLayout: Equatable, Sendable {
  public let prepared: PreparedDocument
  public let width: CGFloat
  public let height: CGFloat
  public let expandedDetails: Set<BlockID>
  public let fragments: [TextFragment]
  public let decorations: [Decoration]
  public let labels: [PlacedLabel]
  public let images: [ImageBox]
  public let targets: [TargetArea]
  public private(set) var regions: [ScrollRegion]
  public let hiddenRanges: [Range<Int>]
  let anchorOffsets: [String: CGFloat]
  let detailsTops: [BlockID: CGFloat]
  let regionIndex: [BlockID: Int]
  let fragmentOrder: [Int]?

  init(prepared: PreparedDocument, input: LayoutInput) {
    var engine = LayoutEngine(prepared: prepared, input: input)
    height = engine.run()
    let out = engine.out
    self.prepared = prepared
    width = input.width
    expandedDetails = input.expandedDetails
    fragments = out.fragments
    decorations = out.decorations
    labels = out.labels
    images = out.images
    targets = out.targets
    regions = out.regions
    var anchors: [String: CGFloat] = [:]
    for anchor in out.anchors where anchors[anchor.name] == nil { anchors[anchor.name] = anchor.y }
    anchorOffsets = anchors
    detailsTops = Dictionary(out.detailsTops.map { ($0.id, $0.y) }, uniquingKeysWith: { first, _ in first })
    regionIndex = Dictionary(out.regions.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    let inTextOrder = zip(out.fragments, out.fragments.dropFirst()).allSatisfy {
      $0.range.lowerBound <= $1.range.lowerBound
    }
    fragmentOrder =
      inTextOrder
      ? nil : out.fragments.indices.sorted { out.fragments[$0].range.lowerBound < out.fragments[$1].range.lowerBound }
    var hidden = prepared.detailsBodies.filter { !input.expandedDetails.contains($0.key) && !$0.value.isEmpty }
      .map(\.value).sorted { $0.lowerBound < $1.lowerBound }
    var merged: [Range<Int>] = []
    while !hidden.isEmpty {
      let next = hidden.removeFirst()
      if let last = merged.last, next.lowerBound <= last.upperBound {
        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, next.upperBound)
      } else {
        merged.append(next)
      }
    }
    hiddenRanges = merged
  }

  public static func == (lhs: PageLayout, rhs: PageLayout) -> Bool {
    lhs.prepared === rhs.prepared && lhs.width == rhs.width && lhs.height == rhs.height
      && lhs.expandedDetails == rhs.expandedDetails && lhs.fragments == rhs.fragments
      && lhs.decorations == rhs.decorations && lhs.labels == rhs.labels && lhs.images == rhs.images
      && lhs.targets == rhs.targets && lhs.regions == rhs.regions && lhs.anchorOffsets == rhs.anchorOffsets
  }

  public func region(_ id: BlockID) -> ScrollRegion? { regionIndex[id].map { regions[$0] } }

  public func offset(of region: BlockID?) -> CGFloat {
    guard let region, let index = regionIndex[region] else { return 0 }
    return regions[index].offset
  }

  public func displayRect(_ rect: CGRect, region: BlockID?) -> CGRect {
    rect.offsetBy(dx: -offset(of: region), dy: 0)
  }

  public func settingScrollOffset(_ offset: CGFloat, for region: BlockID) -> PageLayout {
    guard let index = regionIndex[region] else { return self }
    var copy = self
    let maximum = copy.regions[index].maxOffset
    copy.regions[index].offset = offset.isFinite ? min(max(offset, 0), maximum) : 0
    return copy
  }

  public var scrollOffsets: [BlockID: CGFloat] {
    Dictionary(regions.map { ($0.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
  }
}

extension PreparedDocument {
  public func layout(_ input: LayoutInput) -> PageLayout {
    PageLayout(prepared: self, input: input)
  }

  public func layout(width: CGFloat) -> PageLayout {
    layout(LayoutInput(width: width, expandedDetails: initiallyExpandedDetails))
  }
}

extension PageLayout {
  public func hit(_ point: CGPoint) -> HitResult {
    HitResult(position: textPosition(at: point), target: target(at: point), region: scrollRegion(at: point))
  }

  public func scrollRegion(at point: CGPoint) -> BlockID? {
    regions.first { $0.rect.contains(point) && $0.maxOffset > 0 }?.id
  }

  private func isVisible(_ point: CGPoint, in region: BlockID?) -> Bool {
    guard let region, let index = regionIndex[region] else { return true }
    return regions[index].rect.contains(point)
  }

  public func target(at point: CGPoint) -> HitTarget? {
    for fragment in fragments where isVisible(point, in: fragment.region) {
      let shift = offset(of: fragment.region)
      guard point.y >= fragment.lineTop, point.y < fragment.lineBottom, point.x >= fragment.minX - shift,
        point.x <= fragment.maxX - shift
      else { continue }
      if let link = prepared.segments[fragment.segment].style.link { return .link(link) }
    }
    for image in images.reversed() where image.link != nil && isVisible(point, in: image.region) {
      if displayRect(image.rect, region: image.region).contains(point), let link = image.link { return .link(link) }
    }
    for area in targets.reversed() where isVisible(point, in: area.region) {
      if displayRect(area.rect, region: area.region).contains(point) { return area.target }
    }
    return nil
  }

  public func textPosition(at point: CGPoint) -> TextPosition? {
    var best: (index: Int, score: CGFloat)?
    for (index, fragment) in fragments.enumerated() {
      let shift = offset(of: fragment.region)
      let minX = fragment.minX - shift
      let maxX = fragment.maxX - shift
      let dy: CGFloat =
        point.y < fragment.lineTop
        ? fragment.lineTop - point.y : (point.y >= fragment.lineBottom ? point.y - fragment.lineBottom + 0.5 : 0)
      let dx: CGFloat = point.x < minX ? minX - point.x : (point.x > maxX ? point.x - maxX : 0)
      let score = dy * 1000 + dx
      if best == nil || score < best!.score { best = (index, score) }
      if score == 0 { break }
    }
    guard let best else { return nil }
    let fragment = fragments[best.index]
    let segment = prepared.segments[fragment.segment]
    let local = point.x - (fragment.origin.x - offset(of: fragment.region))
    var offset = min(max(segment.index(at: local), fragment.range.lowerBound), fragment.range.upperBound)
    if offset < prepared.text.length {
      let composed = prepared.text.rangeOfComposedCharacterSequence(at: offset)
      if composed.location < offset {
        let end = composed.location + composed.length
        let before = abs(segment.offset(at: composed.location) - local)
        let after = abs(segment.offset(at: end) - local)
        offset = before <= after ? composed.location : end
      }
    }
    return TextPosition(offset: offset, block: block(containing: offset) ?? BlockID(0))
  }

  public func block(containing offset: Int) -> BlockID? {
    unitIndex(containing: offset).map { prepared.units[$0].block }
  }

  func unitIndex(containing offset: Int) -> Int? {
    let units = prepared.units
    var low = 0
    var high = units.count
    while low < high {
      let mid = (low + high) / 2
      if units[mid].range.lowerBound <= offset { low = mid + 1 } else { high = mid }
    }
    guard low > 0 else { return units.isEmpty ? nil : 0 }
    return low - 1
  }

  public func rects(for range: Range<Int>, scrolled: Bool = true) -> [HighlightRect] {
    guard !range.isEmpty else { return [] }
    var result: [HighlightRect] = []
    func ordered(_ position: Int) -> TextFragment { fragments[fragmentOrder?[position] ?? position] }
    var low = 0
    var high = fragments.count
    while low < high {
      let mid = (low + high) / 2
      if ordered(mid).range.upperBound <= range.lowerBound { low = mid + 1 } else { high = mid }
    }
    var position = low
    while position < fragments.count {
      let fragment = ordered(position)
      position += 1
      if fragment.range.lowerBound >= range.upperBound { break }
      let lower = max(range.lowerBound, fragment.range.lowerBound)
      let upper = min(range.upperBound, fragment.range.upperBound)
      guard lower < upper else { continue }
      let segment = prepared.segments[fragment.segment]
      let shift = scrolled ? offset(of: fragment.region) : 0
      guard let span = segment.span(from: lower, to: upper) else { continue }
      var minX = max(fragment.origin.x + span.lowerBound, fragment.minX) - shift
      var maxX = min(fragment.origin.x + span.upperBound, fragment.maxX) - shift
      if scrolled, let region = fragment.region, let index = regionIndex[region] {
        let clip = regions[index].rect
        minX = max(minX, clip.minX)
        maxX = min(maxX, clip.maxX)
      }
      guard maxX > minX else { continue }
      let rect = CGRect(
        x: minX, y: fragment.lineTop, width: maxX - minX, height: fragment.lineBottom - fragment.lineTop)
      if let last = result.last, last.region == fragment.region, last.rect.minY == rect.minY,
        last.rect.maxY == rect.maxY, abs(last.rect.maxX - rect.minX) < 0.5
      {
        result[result.count - 1].rect = last.rect.union(rect)
      } else {
        result.append(HighlightRect(rect: rect, region: fragment.region))
      }
    }
    return result
  }

  public func plainText(_ range: Range<Int>) -> String {
    let text = prepared.text
    let clamped = max(range.lowerBound, 0)..<min(max(range.upperBound, 0), text.length)
    guard !clamped.isEmpty else { return "" }
    var pieces: [String] = []
    var cursor = clamped.lowerBound
    for hidden in hiddenRanges where hidden.upperBound > cursor && hidden.lowerBound < clamped.upperBound {
      if hidden.lowerBound > cursor {
        pieces.append(text.substring(with: NSRange(location: cursor, length: hidden.lowerBound - cursor)))
      }
      cursor = max(cursor, hidden.upperBound)
    }
    if cursor < clamped.upperBound {
      pieces.append(text.substring(with: NSRange(location: cursor, length: clamped.upperBound - cursor)))
    }
    return pieces.joined()
  }

  public func markdown(_ range: Range<Int>) -> String {
    let units = prepared.units
    guard var index = unitIndex(containing: range.lowerBound) else { return "" }
    var first: Int?
    var last: Int?
    while index < units.count {
      let unit = units[index]
      index += 1
      if unit.range.lowerBound > range.upperBound { break }
      let touched =
        unit.range.overlaps(range) || (unit.range.isEmpty && range.contains(unit.range.lowerBound))
        || (range.isEmpty && (unit.range.contains(range.lowerBound) || unit.range.upperBound == range.lowerBound))
      guard touched else { continue }
      first = min(first ?? unit.source.start.line, unit.source.start.line)
      last = max(last ?? unit.source.end.line, max(unit.source.end.line, unit.source.start.line))
    }
    guard let first, let last else { return "" }
    let lines = prepared.sourceLines
    let lower = min(max(first - 1, 0), lines.count)
    let upper = min(max(last, lower), lines.count)
    return lines[lower..<upper].map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
      .joined(separator: "\n")
  }

  public func sourceRange(for range: Range<Int>) -> SourceRange? {
    let spans = prepared.sourceSpans
    var low = 0
    var high = spans.count
    while low < high {
      let mid = (low + high) / 2
      if spans[mid].range.upperBound < range.lowerBound { low = mid + 1 } else { high = mid }
    }
    var result: SourceRange?
    var emptyMatch: SourceRange?
    for span in spans[low...] {
      if span.range.lowerBound > range.upperBound { break }
      let touched = span.range.overlaps(range) || (range.isEmpty && span.range.contains(range.lowerBound))
      guard touched else { continue }
      if span.source.isEmpty {
        if emptyMatch == nil { emptyMatch = span.source }
      } else if let current = result {
        result = SourceRange(start: min(current.start, span.source.start), end: max(current.end, span.source.end))
      } else {
        result = span.source
      }
    }
    return result ?? emptyMatch
  }

  public func unitRange(at offset: Int) -> Range<Int> {
    guard let index = unitIndex(containing: offset) else { return offset..<offset }
    let unit = prepared.units[index]
    return unit.range.contains(offset) || unit.range.upperBound == offset ? unit.range : offset..<offset
  }

  public func wordRange(at offset: Int) -> Range<Int> {
    let text = prepared.text
    guard text.length > 0 else { return offset..<offset }
    let unit = unitRange(at: offset)
    let scope = unit.isEmpty ? 0..<text.length : unit
    let probe = min(max(offset, scope.lowerBound), scope.upperBound - 1)
    guard probe >= scope.lowerBound else { return offset..<offset }
    let tokenizer = CFStringTokenizerCreate(
      nil, text, CFRange(location: scope.lowerBound, length: scope.count), kCFStringTokenizerUnitWordBoundary, nil)
    _ = CFStringTokenizerGoToTokenAtIndex(tokenizer, probe)
    let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
    guard token.location != kCFNotFound, token.length > 0 else {
      let composed = text.rangeOfComposedCharacterSequence(at: probe)
      return composed.location..<(composed.location + composed.length)
    }
    return token.location..<(token.location + token.length)
  }

  public func link(at offset: Int) -> String? {
    let links = prepared.links
    var low = 0
    var high = links.count
    while low < high {
      let mid = (low + high) / 2
      if links[mid].range.upperBound <= offset { low = mid + 1 } else { high = mid }
    }
    guard low < links.count, links[low].range.contains(offset) else { return nil }
    return links[low].href
  }

  public func find(
    _ query: String, caseSensitive: Bool = false, includeHidden: Bool = false, limit: Int = .max
  ) -> [FindMatch] {
    guard !query.isEmpty, limit > 0 else { return [] }
    let options: NSString.CompareOptions =
      caseSensitive ? [.diacriticInsensitive] : [.caseInsensitive, .diacriticInsensitive]
    let text = prepared.text
    var matches: [FindMatch] = []
    var search = NSRange(location: 0, length: text.length)
    while search.length > 0, matches.count < limit {
      let found = text.range(of: query, options: options, range: search)
      if found.location == NSNotFound || found.length == 0 { break }
      let range = found.location..<(found.location + found.length)
      if !hiddenRanges.contains(where: { $0.overlaps(range) }) {
        matches.append(FindMatch(range: range, rects: rects(for: range)))
      } else if includeHidden {
        matches.append(FindMatch(range: range, rects: []))
      }
      let next = found.location + found.length
      search = NSRange(location: next, length: text.length - next)
    }
    return matches
  }

  public func collapsedDetails(containing offset: Int) -> [BlockID] {
    prepared.detailsBlocks.filter { id in
      !expandedDetails.contains(id) && (prepared.detailsBody(id)?.contains(offset) ?? false)
    }
  }

  public func anchorPosition(_ fragment: String) -> AnchorPosition? {
    var name = fragment.hasPrefix("#") ? String(fragment.dropFirst()) : fragment
    name = name.removingPercentEncoding ?? name
    var candidates = [name]
    if name.hasPrefix(Document.anchorPrefix) { candidates.append(String(name.dropFirst(Document.anchorPrefix.count))) }
    for candidate in candidates {
      if let y = anchorOffsets[candidate] { return AnchorPosition(y: y, collapsedDetails: []) }
      guard let ancestors = prepared.anchorAncestors[candidate] else { continue }
      let collapsed = ancestors.filter { !expandedDetails.contains($0) }
      if let outer = collapsed.first, let y = detailsTops[outer] {
        return AnchorPosition(y: y, collapsedDetails: collapsed)
      }
    }
    return nil
  }
}
