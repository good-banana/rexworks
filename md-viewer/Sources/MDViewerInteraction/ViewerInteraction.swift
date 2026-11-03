import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerDocument
import MDViewerLayout
import MDViewerRender

public struct ViewerInteraction {
  public static let lineRows = 3

  enum PendingAnchor: Equatable {
    case text(offset: Int, delta: CGFloat, ratio: CGFloat)
    case source(line: Int, text: String, delta: CGFloat)
    case fragment(String)
    case offset(CGFloat)
    case revealMatch
  }

  enum Navigation {
    case link(URL, from: History.Entry?, fragment: String?)
    case back(URL, entry: History.Entry, current: History.Entry)
    case forward(URL, entry: History.Entry, current: History.Entry)

    var url: URL {
      switch self {
      case .link(let url, _, _), .back(let url, _, _), .forward(let url, _, _): url
      }
    }
  }

  enum Granularity {
    case character, word, unit
  }

  enum PressKind {
    case content(target: HitTarget?, region: BlockID?)
    case scrollbar(BlockID, grab: CGFloat)
  }

  struct Press {
    var kind: PressKind
    var start: CGPoint
    var moved = false
    var selecting = false
    var selectionBefore: Range<Int>?
    var textOffset: Int?
  }

  struct ClickRecord {
    var time: UInt64
    var point: CGPoint
    var count: Int
  }

  struct TimedMessage {
    var message: StatusMessage
    var expires: UInt64?
  }

  struct ReloadState {
    var selectionText: String?
    var selection: Range<Int>?
    var regionOffsets: [BlockIdentity: CGFloat] = [:]
    var focus: BlockIdentity?
  }

  public var environment: InteractionEnvironment
  public var timing = InteractionTiming()
  public internal(set) var geometry: ViewGeometry
  public internal(set) var baseTypography: Typography
  public internal(set) var zoom: CGFloat = 1
  public internal(set) var file: URL?
  public internal(set) var source = ""
  public internal(set) var layout: PageLayout?
  public internal(set) var offset: CGFloat = 0
  public internal(set) var overlay = RenderOverlay()
  public internal(set) var copyOnSelect: Bool
  public internal(set) var focus: Focusable?
  public internal(set) var findField: String?
  public internal(set) var findQuery: String?
  public internal(set) var helpVisible = false
  public internal(set) var pointerShape = PointerShape.default
  public internal(set) var history = History()
  public internal(set) var pendingRequest: LayoutRequest?
  public var editMode = EditMode.split
  public internal(set) var editorLink: EditorLink?
  public internal(set) var liveBuffer = false
  public internal(set) var editorCursor: EditorCursor?
  public internal(set) var editorPicker: EditorPickerContent?

  var generation = 0
  var pendingAnchor: PendingAnchor?
  var pendingNavigation: Navigation?
  var reloadState: ReloadState?
  var message: TimedMessage?
  var copiedUntil: UInt64?
  var hoverLink: String?
  var hoverCodeBlock: BlockID?
  var pointer: CGPoint?
  var press: Press?
  var clicks: ClickRecord?
  var selectionAnchor: Range<Int>?
  var granularity = Granularity.character
  var autoScrollDeadline: UInt64?
  var wheel = WheelAccelerator()
  var regionWheel = WheelAccelerator()
  var findBefore: (query: String?, offset: CGFloat)?
  var codeFrames: [BlockID: CGRect] = [:]
  var findWindowed = false
  var focusFromPointer = false
  var regionRanges: [BlockID: Range<Int>] = [:]
  var pickerPending: EditRequest?
  var reapplyEditorCursor = false

  public init(geometry: ViewGeometry, typography: Typography, environment: InteractionEnvironment) {
    self.geometry = geometry
    baseTypography = typography
    self.environment = environment
    copyOnSelect = environment.copyOnSelect()
  }

  public var typography: Typography {
    Typography(bodySize: baseTypography.bodySize, zoom: zoom, backingScale: baseTypography.backingScale)
  }

  public var selection: Range<Int>? { overlay.selection }

  public var pageHeight: CGFloat { layout?.height ?? 0 }

  public var maximumOffset: CGFloat {
    let row = geometry.rowHeight
    let overflow = pageHeight - geometry.contentHeight
    guard overflow > 0 else { return 0 }
    return row > 0 ? (overflow / row).rounded(.up) * row : overflow
  }

  public var nextDeadline: UInt64? {
    [message?.expires, copiedUntil, autoScrollDeadline].compactMap { $0 }.min()
  }

  public var status: StatusBarContent {
    let name = file?.lastPathComponent ?? ""
    let folder = file.map { ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
    var shown = message?.message
    if shown == nil, let findQuery {
      shown =
        overlay.findMatches.isEmpty
        ? StatusMessage("No matches", kind: .find)
        : StatusMessage("\((overlay.currentMatch ?? 0) + 1)/\(findCount)", kind: .find)
      if findQuery.isEmpty { shown = nil }
    }
    var hint: String?
    if let hoverLink {
      hint = hoverLink
    } else if overlay.focus != nil, case .link(_, let href) = focus {
      hint = href
    }
    return StatusBarContent(
      fileName: name, folder: folder,
      progress: ScrollProgress(offset: offset, viewport: geometry.contentHeight, content: pageHeight),
      message: shown, hint: hint, findField: findField, editor: editorBadge)
  }

  public var editorBadge: String? {
    guard let editorLink else { return nil }
    guard editorLink.syncsLive else { return "\(editorLink.name): on save" }
    return "\(editorLink.name): \(liveBuffer ? "unsaved" : "live")"
  }

  // MARK: Documents and layout

  public mutating func open(file url: URL, source: String, at now: UInt64 = 0) -> [InteractionEffect] {
    var anchor: PendingAnchor = .offset(0)
    if let navigation = pendingNavigation, navigation.url.standardizedFileURL == url.standardizedFileURL {
      switch navigation {
      case .link(_, let from, let fragment):
        if let from { history.push(from) }
        if let fragment { anchor = .fragment(fragment) }
      case .back(_, let entry, _), .forward(_, let entry, _):
        anchor = .offset(entry.offset)
      }
    }
    pendingNavigation = nil
    file = url
    self.source = source
    overlay = RenderOverlay()
    focus = nil
    focusFromPointer = false
    findField = nil
    findQuery = nil
    findBefore = nil
    hoverLink = nil
    hoverCodeBlock = nil
    press = nil
    selectionAnchor = nil
    autoScrollDeadline = nil
    copiedUntil = nil
    reloadState = nil
    liveBuffer = false
    editorCursor = nil
    reapplyEditorCursor = false
    var effects = requestLayout(source: source, expanded: .some(nil), offsets: [:], fresh: true, anchor: anchor)
    effects.append(.redrawStatusBar)
    return effects
  }

  public mutating func fileChanged(source: String) -> [InteractionEffect] {
    guard file != nil else { return [] }
    self.source = source
    overlay.hoverLink = nil
    let selected = overlay.selection.flatMap { range in layout.map { $0.plainText(range) } }
    var state = ReloadState(selectionText: selected, selection: overlay.selection)
    var carried: CarriedDetails?
    if let layout {
      let details = BlockIdentity.details(in: layout.prepared)
      carried = CarriedDetails(
        expanded: Set(queuedExpandedDetails(in: layout).compactMap { details[$0] }), known: Set(details.values))
      let regions = BlockIdentity.regions(in: layout)
      for region in layout.regions where region.offset > 0 {
        if let identity = regions[region.id] { state.regionOffsets[identity] = region.offset }
      }
      state.focus = focus.flatMap { identity(of: $0, in: layout) }
    }
    reloadState = state
    reapplyEditorCursor = editorCursor != nil
    let anchor = sourceAnchor() ?? .offset(offset)
    return requestLayout(source: source, offsets: [:], carried: carried, anchor: anchor)
  }

  public mutating func loadFailed(_ url: URL, reason: String, at now: UInt64 = 0) -> [InteractionEffect] {
    if let navigation = pendingNavigation, navigation.url.standardizedFileURL == url.standardizedFileURL {
      switch navigation {
      case .link: break
      case .back(_, let entry, _): _ = history.forward(from: entry)
      case .forward(_, let entry, _): _ = history.back(from: entry)
      }
      pendingNavigation = nil
    }
    return show(reason, kind: .error, at: now)
  }

  public mutating func resize(_ geometry: ViewGeometry) -> [InteractionEffect] {
    guard geometry != self.geometry else { return [] }
    let widthChanged = geometry.width != self.geometry.width
    self.geometry = geometry
    guard layout != nil else { return [] }
    if widthChanged { return requestLayout(anchor: topAnchor(ratio: 1)) }
    return setOffset(offset) + [.redrawAll]
  }

  public mutating func assetsChanged() -> [InteractionEffect] {
    guard layout != nil else { return [] }
    return requestLayout(anchor: topAnchor(ratio: 1))
  }

  mutating func requestLayout(
    source newSource: String? = nil, expanded: Set<BlockID>?? = nil, offsets: [BlockID: CGFloat]? = nil,
    carried: CarriedDetails? = nil, fresh: Bool = false, anchor: PendingAnchor, keepAnchor: Bool = false
  ) -> [InteractionEffect] {
    generation += 1
    let current = pendingRequest
    let pendingReload = fresh || current?.source == nil ? nil : current?.carriedDetails
    var carriedResult = carried ?? pendingReload
    var offsets = offsets
    if carried == nil, var folded = pendingReload {
      if case .some(let explicit?) = expanded, let layout {
        let identities = BlockIdentity.details(in: layout.prepared)
        folded.expanded = Set(explicit.compactMap { identities[$0] })
        carriedResult = folded
      }
      offsets = [:]
    }
    var keepsSource = false
    if pendingReload != nil, case .source = pendingAnchor {
      switch anchor {
      case .fragment, .revealMatch: break
      default: keepsSource = true
      }
    }
    if !keepsSource, !(keepAnchor && pendingAnchor != nil) { pendingAnchor = anchor }
    let reuse: PreparedDocument? =
      newSource == nil && current?.source == nil && layout?.prepared.typography == typography
      ? layout?.prepared : nil
    let request = LayoutRequest(
      generation: generation, source: newSource ?? current?.source ?? (reuse == nil ? source : nil), reuse: reuse,
      typography: typography, width: geometry.width,
      expandedDetails: expanded ?? current?.expandedDetails ?? layout?.expandedDetails,
      scrollOffsets: offsets ?? current?.scrollOffsets ?? layout?.scrollOffsets ?? [:],
      carriedDetails: carriedResult)
    pendingRequest = request
    return [.requestLayout(request)]
  }

  public mutating func apply(_ page: PageLayout, for request: LayoutRequest, at now: UInt64 = 0)
    -> [InteractionEffect]
  {
    guard request.generation == generation else { return [] }
    pendingRequest = nil
    let previous = layout
    var page = page
    if let previous, previous.prepared === page.prepared {
      for region in previous.regions where region.offset != (request.scrollOffsets[region.id] ?? 0) {
        page = page.settingScrollOffset(region.offset, for: region.id)
      }
    }
    if let state = reloadState, request.carriedDetails != nil {
      let regions = BlockIdentity.regions(in: page)
      for (id, identity) in regions {
        if let value = state.regionOffsets[identity] { page = page.settingScrollOffset(value, for: id) }
      }
      let ringShown = overlay.focus != nil
      focus = state.focus.flatMap { focusable(for: $0, in: page) }
      if focus == nil { focusFromPointer = false }
      overlay.focus = ringShown ? focus.map(ring(for:)) : nil
    }
    layout = page
    overlay.hoverLink = nil
    codeFrames = Self.codeBlockFrames(in: page)
    regionRanges = Self.regionRanges(in: page)
    var target = offset
    var effects: [InteractionEffect] = [.layoutChanged]
    switch pendingAnchor {
    case .text(let textOffset, let delta, let ratio):
      if let top = lineTop(near: textOffset, in: page) { target = top + delta * ratio }
    case .source(let line, let text, let delta):
      if let top = lineTop(ofSourceLine: line, text: text, in: page) { target = top + delta }
    case .fragment(let name):
      if let position = page.anchorPosition(name) {
        if !position.collapsedDetails.isEmpty {
          let expanded = page.expandedDetails.union(position.collapsedDetails)
          return effects + requestLayout(expanded: .some(expanded), anchor: .fragment(name))
        }
        target = position.y
      } else {
        effects += show("No anchor #\(name)", kind: .error, at: now)
      }
    case .offset(let value):
      target = value
    case .revealMatch, nil:
      break
    }
    if let cursor = editorCursor {
      overlay.sourceCursor = sourceCursorBar(for: cursor, in: page)
      if reapplyEditorCursor, let value = editorCursorOffset(cursor, in: page) { target = value }
    }
    reapplyEditorCursor = false
    let revealing = pendingAnchor == .revealMatch
    pendingAnchor = nil
    restoreSelection(previous: previous, page: page)
    refreshFind(keepingNear: overlay.currentMatch.map { overlay.findMatches[$0].range.lowerBound })
    refreshFocus(page)
    if revealing {
      offset = snapped(target)
      effects += revealCurrentMatch()
      target = offset
    }
    if let block = overlay.copyButton?.block, page.prepared.codeBlocks[block] == nil { overlay.copyButton = nil }
    effects += setOffset(target, force: true)
    effects.append(.redrawAll)
    return effects
  }

  static func regionRanges(in page: PageLayout) -> [BlockID: Range<Int>] {
    var spans: [BlockID: Range<Int>] = [:]
    for fragment in page.fragments {
      guard let region = fragment.region else { continue }
      let span = spans[region] ?? fragment.range
      spans[region] = min(span.lowerBound, fragment.range.lowerBound)..<max(span.upperBound, fragment.range.upperBound)
    }
    return spans
  }

  func identity(of item: Focusable, in page: PageLayout) -> BlockIdentity? {
    switch item {
    case .details(let id): BlockIdentity.details(in: page.prepared)[id]
    case .codeBlock(let id):
      BlockIdentity.numbered(
        page.prepared.codeBlocks.filter { !$0.value.isDiagram }.map { ($0.key, .code, $0.value.code) })[id]
    case .table(let id): BlockIdentity.regions(in: page)[id]
    case .video: nil
    case .link(let range, _): BlockIdentity.links(in: page)[range]
    }
  }

  func focusable(for identity: BlockIdentity, in page: PageLayout) -> Focusable? {
    switch identity.kind {
    case .details:
      return BlockIdentity.details(in: page.prepared).first { $0.value == identity }.map { .details($0.key) }
    case .code:
      let blocks = page.prepared.codeBlocks.filter { !$0.value.isDiagram }.map {
        ($0.key, BlockIdentity.Kind.code, $0.value.code)
      }
      return BlockIdentity.numbered(blocks).first { $0.value == identity }.map { .codeBlock($0.key) }
    case .table:
      return BlockIdentity.regions(in: page).first { $0.value == identity }.map { .table($0.key) }
    case .link:
      guard let range = BlockIdentity.links(in: page).first(where: { $0.value == identity })?.key,
        let link = page.prepared.links.first(where: { $0.range == range })
      else { return nil }
      return .link(range, href: link.href)
    }
  }

  static func codeBlockFrames(in page: PageLayout) -> [BlockID: CGRect] {
    let backgrounds = page.decorations.filter { $0.kind == .codeBlockBackground }.map(\.rect)
    var frames: [BlockID: CGRect] = [:]
    for area in page.targets {
      guard case .copyCode(let id, _) = area.target else { continue }
      let center = CGPoint(x: area.rect.midX, y: area.rect.midY)
      frames[id] = backgrounds.first { $0.contains(center) && $0.minY <= area.rect.minY } ?? area.rect
    }
    return frames
  }

  mutating func restoreSelection(previous: PageLayout?, page: PageLayout) {
    guard let state = reloadState else {
      if let selection = overlay.selection, selection.upperBound > page.prepared.text.length {
        overlay.selection = nil
        selectionAnchor = nil
      }
      return
    }
    reloadState = nil
    guard let text = state.selectionText, !text.isEmpty, let old = state.selection else {
      overlay.selection = nil
      selectionAnchor = nil
      return
    }
    let length = page.prepared.text.length
    if old.upperBound <= length, page.plainText(old) == text { return }
    let haystack = page.prepared.text
    var best: Range<Int>?
    var search = NSRange(location: 0, length: length)
    while search.length > 0 {
      let found = haystack.range(of: text, options: [], range: search)
      if found.location == NSNotFound || found.length == 0 { break }
      let range = found.location..<(found.location + found.length)
      if page.plainText(range) == text,
        best.map({ abs($0.lowerBound - old.lowerBound) > abs(range.lowerBound - old.lowerBound) }) ?? true
      {
        best = range
      }
      search = NSRange(location: found.location + 1, length: length - found.location - 1)
    }
    overlay.selection = best
    selectionAnchor = best.map { $0.lowerBound..<$0.lowerBound }
  }

  mutating func refreshFocus(_ page: PageLayout) {
    guard let current = focus else { return }
    if !focusables(in: page).contains(current) {
      focus = nil
      focusFromPointer = false
      overlay.focus = nil
    } else if overlay.focus != nil {
      overlay.focus = ring(for: current)
    }
  }

  func topLine(in page: PageLayout, at y: CGFloat? = nil) -> TextFragment? {
    let top = y ?? offset
    var best: TextFragment?
    for fragment in page.fragments where fragment.lineBottom > top {
      if best == nil || fragment.lineTop < best!.lineTop
        || (fragment.lineTop == best!.lineTop && fragment.range.lowerBound < best!.range.lowerBound)
      {
        best = fragment
      }
    }
    return best
  }

  func topAnchor(ratio: CGFloat) -> PendingAnchor {
    guard let layout, offset > 0, let fragment = topLine(in: layout) else { return .offset(offset * ratio) }
    return .text(offset: fragment.range.lowerBound, delta: offset - fragment.lineTop, ratio: ratio)
  }

  func sourceAnchor() -> PendingAnchor? {
    guard let layout, offset > 0, let fragment = topLine(in: layout) else { return nil }
    let units = layout.prepared.units
    guard let unit = units.last(where: { $0.range.lowerBound <= fragment.range.lowerBound }) ?? units.first,
      let top = lineTop(near: unit.range.lowerBound, in: layout)
    else { return nil }
    return .source(line: unit.source.start.line, text: layout.plainText(unit.range), delta: offset - top)
  }

  func lineTop(near textOffset: Int, in page: PageLayout) -> CGFloat? {
    var containing: TextFragment?
    var before: TextFragment?
    for fragment in page.fragments {
      if fragment.range.contains(textOffset) || (fragment.range.isEmpty && fragment.range.lowerBound == textOffset) {
        if containing == nil || fragment.lineTop < containing!.lineTop { containing = fragment }
      } else if fragment.range.lowerBound <= textOffset,
        before == nil || fragment.range.lowerBound > before!.range.lowerBound
          || (fragment.range.lowerBound == before!.range.lowerBound && fragment.lineTop > before!.lineTop)
      {
        before = fragment
      }
    }
    return (containing ?? before)?.lineTop
  }

  func lineTop(ofSourceLine line: Int, text: String, in page: PageLayout) -> CGFloat? {
    var same: TextUnit?
    var after: TextUnit?
    for unit in page.prepared.units {
      let distance = abs(unit.source.start.line - line)
      if !text.isEmpty, page.plainText(unit.range) == text,
        same.map({ distance < abs($0.source.start.line - line) }) ?? true
      {
        same = unit
      }
      if unit.source.start.line >= line, after.map({ unit.source.start.line < $0.source.start.line }) ?? true {
        after = unit
      }
    }
    let unit = same ?? after ?? page.prepared.units.last
    return unit.flatMap { lineTop(near: $0.range.lowerBound, in: page) }
  }

  // MARK: Editor

  public mutating func setEditorLink(_ link: EditorLink?) -> [InteractionEffect] {
    guard link != editorLink else { return [] }
    editorLink = link
    return [.redrawStatusBar]
  }

  public mutating func setLiveBuffer(_ live: Bool) -> [InteractionEffect] {
    guard live != liveBuffer else { return [] }
    liveBuffer = live
    return [.redrawStatusBar]
  }

  public mutating func showEditorPicker(
    candidates: [EditorCandidate], mode: EditMode, pending: EditRequest?
  ) -> [InteractionEffect] {
    editorPicker = EditorPickerContent(candidates: candidates, mode: mode)
    pickerPending = pending
    helpVisible = false
    overlay.hoverLink = nil
    return setPointerShape(.default) + [.redrawAll]
  }

  public mutating func applyEditorCursor(_ cursor: EditorCursor) -> [InteractionEffect] {
    editorCursor = cursor
    guard let layout else { return [] }
    var effects = setSourceCursorBar(sourceCursorBar(for: cursor, in: layout))
    if let target = editorCursorOffset(cursor, in: layout) { effects += setOffset(target) }
    return effects
  }

  public mutating func clearEditorCursor() -> [InteractionEffect] {
    editorCursor = nil
    reapplyEditorCursor = false
    return setSourceCursorBar(nil)
  }

  public func y(forSourceLine line: Int) -> CGFloat? {
    guard let layout else { return nil }
    return sourceLineBand(line, in: layout)?.top
  }

  public var editLine: Int {
    guard let layout else { return 1 }
    if let selection = overlay.selection, !selection.isEmpty,
      let line = codeSourceLine(atText: selection.lowerBound, in: layout)
        ?? layout.sourceRange(for: selection)?.start.line, line >= 1
    {
      return line
    }
    let units = layout.prepared.units
    if let fragment = topLine(in: layout),
      let index = units.lastIndex(where: { $0.range.lowerBound <= fragment.range.lowerBound })
        ?? (units.isEmpty ? nil : 0)
    {
      let line = codeSourceLine(ofUnit: index, in: layout) ?? units[index].source.start.line
      if line >= 1 { return line }
    }
    return 1
  }

  func clickLine(atText offset: Int, in layout: PageLayout) -> Int? {
    if let line = codeSourceLine(atText: offset, in: layout) { return line }
    let source = layout.sourceRange(for: offset..<offset) ?? layout.sourceRange(for: max(offset - 1, 0)..<offset)
    if let line = source?.start.line, line >= 1 { return line }
    let units = layout.prepared.units
    guard let unit = units.last(where: { $0.range.lowerBound <= offset }), unit.source.start.line >= 1 else {
      return nil
    }
    return unit.source.start.line
  }

  func codeSourceLine(atText offset: Int, in layout: PageLayout) -> Int? {
    guard let index = layout.prepared.units.lastIndex(where: { $0.range.lowerBound <= offset }) else { return nil }
    return codeSourceLine(ofUnit: index, in: layout)
  }

  func codeSourceLine(ofUnit index: Int, in layout: PageLayout) -> Int? {
    let units = layout.prepared.units
    let unit = units[index]
    guard unit.kind == .codeLine else { return nil }
    let lines = units.indices.filter { units[$0].kind == .codeLine && units[$0].block == unit.block }
    guard let position = lines.firstIndex(of: index) else { return nil }
    return unit.source.start.line + Self.codeLead(unit.source, lines: lines.count) + position
  }

  static func codeLead(_ source: SourceRange, lines: Int) -> Int {
    source.end.line - source.start.line + 1 > lines ? 1 : 0
  }

  func sourceLineBand(_ line: Int, in page: PageLayout) -> (top: CGFloat, bottom: CGFloat)? {
    let units = page.prepared.units
    var spans: [SourceRange] = []
    for unit in units
    where !unit.source.isEmpty && unit.source.start.line <= line && line <= unit.source.end.line
      && !spans.contains(unit.source)
    {
      spans.append(unit.source)
    }
    spans.sort { $0.end.line - $0.start.line < $1.end.line - $1.start.line }
    for span in spans {
      let group = units.filter { $0.source == span }
      let lines: [TextUnit]
      var fraction: CGFloat = 0
      if group.allSatisfy({ $0.kind == .codeLine }) {
        let index = line - span.start.line - Self.codeLead(span, lines: group.count)
        lines = [group[min(max(index, 0), group.count - 1)]]
      } else {
        lines = group
        fraction = CGFloat(line - span.start.line) / CGFloat(span.end.line - span.start.line + 1)
      }
      let covered = lines[0].range.lowerBound..<lines[lines.count - 1].range.upperBound
      let fragments = page.fragments.filter { fragment in
        fragment.range.overlaps(covered) || (fragment.range.isEmpty && covered.contains(fragment.range.lowerBound))
      }
      guard let top = fragments.map(\.lineTop).min(), let bottom = fragments.map(\.lineBottom).max() else {
        continue
      }
      let y = top + fraction * (bottom - top)
      let row =
        fragments.filter { $0.lineTop <= y }.max { $0.lineTop < $1.lineTop }
        ?? fragments.min { $0.lineTop < $1.lineTop }
      if let row { return (row.lineTop, row.lineBottom) }
    }
    guard let top = lineTop(ofSourceLine: line, text: "", in: page) else { return nil }
    let bottom = page.fragments.filter { $0.lineTop == top }.map(\.lineBottom).max() ?? top + geometry.rowHeight
    return (top, bottom)
  }

  func editorCursorOffset(_ cursor: EditorCursor, in page: PageLayout) -> CGFloat? {
    guard let band = sourceLineBand(cursor.line, in: page) else { return nil }
    let fraction =
      cursor.height > 0 ? min(max(CGFloat(cursor.line - cursor.top) / CGFloat(cursor.height), 0), 1) : 0
    return band.top - fraction * geometry.contentHeight
  }

  func sourceCursorBar(for cursor: EditorCursor, in page: PageLayout) -> CGRect? {
    guard let band = sourceLineBand(cursor.line, in: page) else { return nil }
    let typography = page.prepared.typography
    let width = max(typography.pixels(em: 0.2).rounded(), 2)
    return CGRect(
      x: typography.pixels(em: 0.9).rounded(), y: band.top, width: width, height: max(band.bottom - band.top, 1))
  }

  mutating func setSourceCursorBar(_ bar: CGRect?) -> [InteractionEffect] {
    let old = overlay.sourceCursor
    guard bar != old else { return [] }
    overlay.sourceCursor = bar
    return [old, bar].compactMap { $0 }.map { .redraw($0.insetBy(dx: -2, dy: -2)) }
  }

  // MARK: Vertical scrolling

  func snapped(_ target: CGFloat) -> CGFloat {
    let maximum = maximumOffset
    let clamped = target.isFinite ? min(max(target, 0), maximum) : (target > 0 ? maximum : 0)
    let row = geometry.rowHeight
    return row > 0 ? min((clamped / row).rounded() * row, maximum) : clamped
  }

  mutating func setOffset(_ target: CGFloat, force: Bool = false) -> [InteractionEffect] {
    let next = snapped(target)
    guard next != offset || force else { return [] }
    offset = next
    return [.scroll(to: next)]
  }

  mutating func scroll(by delta: CGFloat) -> [InteractionEffect] {
    setOffset(offset + delta)
  }

  mutating func reveal(_ rect: CGRect, margin: CGFloat? = nil, centered: Bool = false) -> [InteractionEffect] {
    let pad = margin ?? geometry.rowHeight
    let height = geometry.contentHeight
    if rect.minY >= offset + pad * 0.5, rect.maxY <= offset + height - pad * 0.5 { return [] }
    if centered { return setOffset(rect.minY - height / 3) }
    if rect.minY < offset || rect.height > height - pad * 2 { return setOffset(rect.minY - pad) }
    return setOffset(rect.maxY - height + pad)
  }

  // MARK: Messages

  public mutating func show(_ text: String, kind: StatusMessage.Kind, at now: UInt64) -> [InteractionEffect] {
    let duration: UInt64 =
      switch kind {
      case .success: timing.successNanoseconds
      case .error: timing.errorNanoseconds
      case .info, .find: timing.infoNanoseconds
      }
    message = TimedMessage(message: StatusMessage(text, kind: kind), expires: now + duration)
    return [.redrawStatusBar]
  }

  public mutating func tick(at now: UInt64) -> [InteractionEffect] {
    var effects: [InteractionEffect] = []
    if let expires = message?.expires, now >= expires {
      message = nil
      effects.append(.redrawStatusBar)
    }
    if let until = copiedUntil, now >= until {
      copiedUntil = nil
      if let block = overlay.copyButton?.block {
        overlay.copyButton = hoverCodeBlock == block ? CopyButtonOverlay(block: block) : nil
        effects += redrawCopyButton(block)
      }
    }
    if let deadline = autoScrollDeadline, now >= deadline {
      effects += autoScroll(at: now)
    }
    return effects
  }
}
