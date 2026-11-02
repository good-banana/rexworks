import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout
import MDViewerRender

extension ViewerInteraction {
  public mutating func handle(_ event: InputEvent, at now: UInt64) -> [InteractionEffect] {
    switch event {
    case .key(let key): handle(key: key, at: now)
    case .mouse(let mouse): handle(mouse: mouse, at: now)
    default: []
    }
  }

  var lineStep: CGFloat { CGFloat(Self.lineRows) * max(geometry.rowHeight, 1) }

  var focusedRegion: BlockID? {
    let id: BlockID
    switch focus {
    case .codeBlock(let block), .table(let block): id = block
    default: return nil
    }
    guard let region = layout?.region(id), region.maxOffset > 0,
      region.rect.maxY > offset, region.rect.minY < offset + geometry.contentHeight
    else { return nil }
    return id
  }

  mutating func handle(key: Key, at now: UInt64) -> [InteractionEffect] {
    if findField != nil { return handleFindField(key, at: now) }
    let view = geometry.contentHeight
    switch key {
    case .char("j"), .down: return scroll(by: lineStep)
    case .char("k"), .up: return scroll(by: -lineStep)
    case .char("d"): return scroll(by: view / 2)
    case .char("u"): return scroll(by: -view / 2)
    case .char(" "), .pageDown: return scroll(by: view)
    case .char("b"), .pageUp: return scroll(by: -view)
    case .char("g"), .home: return setOffset(0)
    case .char("G"), .end: return setOffset(.greatestFiniteMagnitude)
    case .char("r"):
      copyOnSelect = environment.copyOnSelect()
      return [.reload]
    case .tab: return moveFocus(forward: true)
    case .backTab: return moveFocus(forward: false)
    case .enter: return focusFromPointer ? [] : activateFocus(at: now)
    case .escape: return escape()
    case .backspace:
      return focusedRegion == nil || focusFromPointer ? goBack(at: now) : []
    case .char("h"):
      if let region = focusedRegion { return scrollRegion(region, by: -regionStep) }
      return goBack(at: now)
    case .char("l"):
      if let region = focusedRegion { return scrollRegion(region, by: regionStep) }
      return []
    case .left, .right:
      guard let region = focusedRegion ?? pointerRegion else { return [] }
      return scrollRegion(region, by: key == .left ? -regionStep : regionStep)
    case .char("L"), .shiftBackspace: return goForward(at: now)
    case .char("/"): return openFind()
    case .char("n"): return stepMatch(forward: true, at: now)
    case .char("N"): return stepMatch(forward: false, at: now)
    case .char("y"), .command("c"): return copySelection(markdown: false, at: now)
    case .command("a"): return selectAll()
    case .char("Y"): return copySelection(markdown: true, at: now)
    case .char("c"):
      guard !focusFromPointer, case .codeBlock(let id) = focus else { return [] }
      return copyCode(id, at: now)
    case .char("+"), .char("="): return setZoom(ZoomSteps.next(after: zoom), at: now)
    case .char("-"): return setZoom(ZoomSteps.previous(before: zoom), at: now)
    case .char("0"): return setZoom(1, at: now)
    case .char("q"), .ctrl("q"), .ctrl("c"): return [.quit]
    default: return []
    }
  }

  mutating func escape() -> [InteractionEffect] {
    if findQuery != nil { return closeFind() }
    if overlay.selection != nil { return setSelection(nil) }
    if focus != nil { return setFocus(nil) }
    return []
  }

  mutating func setZoom(_ level: CGFloat, at now: UInt64) -> [InteractionEffect] {
    let clamped = min(max(level, ZoomSteps.levels[0]), ZoomSteps.levels[ZoomSteps.levels.count - 1])
    guard clamped != zoom, layout != nil else { return [] }
    let shown = layout?.prepared.typography.zoom ?? zoom
    let ratio = clamped / shown
    let anchor = topAnchor(ratio: ratio)
    zoom = clamped
    let offsets = (layout?.scrollOffsets ?? [:]).mapValues { $0 * ratio }
    return requestLayout(source: source, offsets: offsets, anchor: anchor)
      + show("Zoom \(Int((clamped * 100).rounded()))%", kind: .info, at: now)
  }

  // MARK: Focus

  func focusables(in page: PageLayout) -> [Focusable] {
    var items: [(CGRect, Focusable)] = []
    for link in page.prepared.links where !page.hiddenRanges.contains(where: { $0.overlaps(link.range) }) {
      if let first = page.rects(for: link.range, scrolled: false).first {
        items.append((first.rect, .link(link.range, href: link.href)))
      }
    }
    for area in page.targets {
      switch area.target {
      case .detailsToggle(let id): items.append((area.rect, .details(id)))
      case .copyCode(let id, _): items.append((codeFrames[id] ?? area.rect, .codeBlock(id)))
      default: break
      }
    }
    for region in page.regions where region.kind == .table && region.maxOffset > 0 {
      items.append((region.rect, .table(region.id)))
    }
    return items.sorted { lhs, rhs in
      abs(lhs.0.minY - rhs.0.minY) > 0.5 ? lhs.0.minY < rhs.0.minY : lhs.0.minX < rhs.0.minX
    }.map(\.1)
  }

  func ring(for item: Focusable) -> FocusRing {
    switch item {
    case .link(let range, _): .text(range)
    case .details(let id): .target(.detailsToggle(id))
    case .codeBlock(let id): .codeBlock(id)
    case .table(let id): .region(id)
    }
  }

  func rect(for item: Focusable, in page: PageLayout) -> CGRect? {
    switch item {
    case .link(let range, _):
      return page.rects(for: range, scrolled: false).map { page.displayRect($0.rect, region: $0.region) }
        .reduce(nil) { $0?.union($1) ?? $1 }
    case .details(let id):
      return page.targets.first { $0.target == .detailsToggle(id) }?.rect
    case .codeBlock(let id):
      return codeFrames[id]
    case .table(let id):
      return page.region(id)?.rect
    }
  }

  func focusRedrawRect(_ item: Focusable?, in page: PageLayout) -> CGRect? {
    guard let item, let rect = rect(for: item, in: page) else { return nil }
    let pad = page.prepared.typography.pixels(em: 0.5)
    return rect.insetBy(dx: -pad, dy: -pad)
  }

  mutating func setFocus(_ item: Focusable?, fromPointer: Bool = false) -> [InteractionEffect] {
    guard let layout else { return [] }
    let ring = fromPointer ? nil : item.map(ring(for:))
    guard item != focus || ring != overlay.focus else { return [] }
    var effects: [InteractionEffect] = []
    if overlay.focus != nil, let rect = focusRedrawRect(focus, in: layout) { effects.append(.redraw(rect)) }
    if ring != nil, let rect = focusRedrawRect(item, in: layout) { effects.append(.redraw(rect)) }
    focus = item
    focusFromPointer = item != nil && fromPointer
    overlay.focus = ring
    if !fromPointer, let item {
      if case .link(let range, _) = item, let region = regionOf(range) {
        effects += revealHorizontally(range, in: region)
      }
      if let rect = rect(for: item, in: self.layout ?? layout) { effects += reveal(rect) }
    }
    effects.append(.redrawStatusBar)
    return effects
  }

  func regionOf(_ range: Range<Int>) -> BlockID? {
    regionRanges.first { $0.value.overlaps(range) }?.key
  }

  mutating func moveFocus(forward: Bool) -> [InteractionEffect] {
    guard let layout else { return [] }
    let items = focusables(in: layout)
    guard !items.isEmpty else { return [] }
    let index: Int
    if let current = focus.flatMap({ items.firstIndex(of: $0) }) {
      index = cycle(from: current, count: items.count, forward: forward) ?? 0
    } else {
      let visible = items.indices.filter { position in
        guard let rect = rect(for: items[position], in: layout) else { return false }
        return rect.maxY > offset && rect.minY < offset + geometry.contentHeight
      }
      index = (forward ? visible.first : visible.last) ?? (forward ? 0 : items.count - 1)
    }
    return setFocus(items[index])
  }

  mutating func activateFocus(at now: UInt64) -> [InteractionEffect] {
    switch focus {
    case .link(_, let href): return follow(href, at: now)
    case .details(let id): return toggleDetails(id)
    case .codeBlock(let id): return copyCode(id, at: now)
    case .table, nil: return []
    }
  }

  // MARK: Find

  mutating func openFind() -> [InteractionEffect] {
    findBefore = (findQuery, offset)
    findField = ""
    return [.redrawStatusBar]
  }

  mutating func handleFindField(_ key: Key, at now: UInt64) -> [InteractionEffect] {
    switch key {
    case .char(let character):
      findField?.append(character)
      return updateFind(findField ?? "")
    case .backspace:
      if findField?.isEmpty == true { return cancelFind() }
      findField?.removeLast()
      return updateFind(findField ?? "")
    case .enter:
      let query = findField ?? ""
      findField = nil
      findBefore = nil
      if query.isEmpty { return closeFind() }
      return [.redrawStatusBar]
    case .escape:
      return cancelFind()
    case .ctrl("c"), .ctrl("q"):
      return [.quit]
    default:
      return []
    }
  }

  mutating func cancelFind() -> [InteractionEffect] {
    let before = findBefore
    findField = nil
    findBefore = nil
    var effects = closeFind()
    if let before {
      if let query = before.query { effects += updateFind(query) }
      effects += setOffset(before.offset)
    }
    return effects
  }

  mutating func closeFind() -> [InteractionEffect] {
    findField = nil
    findQuery = nil
    let rects = matchRects(overlay.findMatches)
    overlay.findMatches = []
    overlay.currentMatch = nil
    return redraws(rects) + [.redrawStatusBar]
  }

  static let findLimit = 5000
  static let maximumBandRedraws = 24

  func redraws(_ bands: [CGRect]) -> [InteractionEffect] {
    let visible = CGRect(x: 0, y: offset, width: geometry.width, height: geometry.contentHeight)
    let shown = bands.filter { $0.intersects(visible) }
    if shown.count > Self.maximumBandRedraws { return [.redrawAll] }
    return shown.map { .redraw($0) }
  }

  mutating func loadMatches(_ query: String, from start: Int, backward: Bool = false, in layout: PageLayout) {
    var found = layout.find(
      query, caseSensitive: Self.isCaseSensitive(query), includeHidden: true, from: start, backward: backward,
      limit: Self.findLimit)
    findWindowed = found.count >= Self.findLimit
    if findWindowed {
      if backward { found.reverse() }
    } else {
      found.sort { $0.range.lowerBound < $1.range.lowerBound }
    }
    overlay.findMatches = found
  }

  func viewTextOffset(at y: CGFloat, in layout: PageLayout) -> Int {
    topLine(in: layout, at: y)?.range.lowerBound ?? 0
  }

  func matchTop(_ range: Range<Int>, in layout: PageLayout) -> CGFloat {
    layout.rects(for: range, scrolled: false).first?.rect.minY ?? lineTop(near: range.lowerBound, in: layout) ?? 0
  }

  var findCount: String {
    findWindowed ? "\(overlay.findMatches.count)+" : "\(overlay.findMatches.count)"
  }

  func matchRects(_ matches: [FindMatch]) -> [CGRect] {
    let rects = matches.flatMap(\.rects).map(\.rect)
    var merged: [CGRect] = []
    for rect in rects {
      let band = CGRect(x: 0, y: rect.minY, width: geometry.width, height: rect.height)
      if let last = merged.last, band.minY <= last.maxY + 1 {
        merged[merged.count - 1] = last.union(band)
      } else {
        merged.append(band)
      }
    }
    return merged
  }

  public static func isCaseSensitive(_ query: String) -> Bool {
    query.contains { $0.isUppercase }
  }

  mutating func updateFind(_ query: String) -> [InteractionEffect] {
    let old = matchRects(overlay.findMatches)
    findQuery = query
    overlay.findMatches = []
    overlay.currentMatch = nil
    guard let layout, !query.isEmpty else { return redraws(old) + [.redrawStatusBar] }
    let top = findBefore?.offset ?? offset
    loadMatches(query, from: viewTextOffset(at: top, in: layout), in: layout)
    if !overlay.findMatches.isEmpty {
      overlay.currentMatch =
        findWindowed ? 0 : overlay.findMatches.firstIndex { matchTop($0.range, in: layout) >= top } ?? 0
    }
    var effects = redraws(old + matchRects(overlay.findMatches))
    effects += revealCurrentMatch()
    effects.append(.redrawStatusBar)
    return effects
  }

  mutating func refreshFind(keepingNear location: Int?) {
    guard let layout, let query = findQuery, !query.isEmpty else { return }
    loadMatches(query, from: location ?? viewTextOffset(at: offset, in: layout), in: layout)
    guard !overlay.findMatches.isEmpty else {
      overlay.currentMatch = nil
      return
    }
    guard let location, !findWindowed else {
      overlay.currentMatch = 0
      return
    }
    overlay.currentMatch = overlay.findMatches.indices.min {
      abs(overlay.findMatches[$0].range.lowerBound - location)
        < abs(overlay.findMatches[$1].range.lowerBound - location)
    }
  }

  mutating func stepMatch(forward: Bool, at now: UInt64) -> [InteractionEffect] {
    guard findQuery != nil else { return show("No search; / to search", kind: .info, at: now) }
    guard !overlay.findMatches.isEmpty else { return show("No matches", kind: .find, at: now) }
    let old = overlay.currentMatch
    let count = overlay.findMatches.count
    var effects: [InteractionEffect]
    if findWindowed, let layout, let query = findQuery, let current = old,
      forward ? current == count - 1 : current == 0
    {
      let previous = overlay.findMatches
      let edge = previous[current].range
      loadMatches(query, from: forward ? edge.upperBound : edge.lowerBound, backward: !forward, in: layout)
      overlay.currentMatch = overlay.findMatches.isEmpty ? nil : (forward ? 0 : overlay.findMatches.count - 1)
      effects = redraws(matchRects(previous) + matchRects(overlay.findMatches))
    } else {
      overlay.currentMatch = cycle(from: old, count: count, forward: forward)
      effects = redraws(matchRects([old, overlay.currentMatch].compactMap { $0 }.map { overlay.findMatches[$0] }))
    }
    effects += revealCurrentMatch()
    effects.append(.redrawStatusBar)
    return effects
  }

  mutating func revealCurrentMatch() -> [InteractionEffect] {
    guard let index = overlay.currentMatch, overlay.findMatches.indices.contains(index) else { return [] }
    let range = overlay.findMatches[index].range
    if let layout {
      let collapsed = layout.collapsedDetails(containing: range.lowerBound)
      if !collapsed.isEmpty {
        return requestLayout(expanded: .some(layout.expandedDetails.union(collapsed)), anchor: .revealMatch)
      }
    }
    var effects: [InteractionEffect] = []
    if let region = regionOf(range) { effects += revealHorizontally(range, in: region) }
    if let rect = layout?.rects(for: range, scrolled: false).first?.rect { effects += reveal(rect, centered: true) }
    return effects
  }
}
