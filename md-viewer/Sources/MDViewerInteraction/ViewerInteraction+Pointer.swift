import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout
import MDViewerRender

extension ViewerInteraction {
  var regionStep: CGFloat { max(typography.pixels(em: 3), geometry.rowHeight * 2) }

  var dragThreshold: CGFloat { max(3 * typography.backingScale, 1) }

  func pagePoint(_ pane: CGPoint) -> CGPoint {
    let y = min(max(pane.y, 0), max(geometry.contentHeight - 1, 0))
    return CGPoint(x: min(max(pane.x, 0), max(geometry.width - 1, 0)), y: y + offset)
  }

  var pointerRegion: BlockID? {
    guard let pointer, pointer.y < geometry.contentHeight else { return nil }
    return layout?.scrollRegion(at: pagePoint(pointer))
  }

  mutating func handle(mouse: MouseEvent, at now: UInt64) -> [InteractionEffect] {
    let pane = CGPoint(x: CGFloat(mouse.x), y: CGFloat(mouse.y))
    pointer = pane
    switch mouse.kind {
    case .wheelUp, .wheelDown:
      let direction = mouse.kind == .wheelUp ? -1 : 1
      if mouse.modifiers.contains(.shift), let region = pointerRegion {
        let step = regionStep * CGFloat(regionWheel.multiplier(direction: direction, at: now))
        return scrollRegion(region, by: CGFloat(direction) * step)
      }
      let rows = wheel.multiplier(direction: direction, at: now)
      return scroll(by: CGFloat(direction * rows) * max(geometry.rowHeight, 1))
    case .wheelLeft, .wheelRight:
      guard let region = pointerRegion else { return [] }
      let direction = mouse.kind == .wheelLeft ? -1 : 1
      let step = regionStep * CGFloat(regionWheel.multiplier(direction: direction, at: now))
      return scrollRegion(region, by: CGFloat(direction) * step)
    case .press:
      guard mouse.button == 0 else { return [] }
      return pressed(at: pane, now: now)
    case .motion:
      if mouse.button == 0, press != nil { return dragged(to: pane, now: now) }
      if mouse.button == 3, press != nil { return released(at: now) + hovered(at: pane) }
      return hovered(at: pane)
    case .release:
      guard press != nil, mouse.button == 0 else { return [] }
      return released(at: now)
    }
  }

  mutating func setPointerShape(_ shape: PointerShape) -> [InteractionEffect] {
    guard shape != pointerShape else { return [] }
    pointerShape = shape
    return [.pointerShape(shape)]
  }

  mutating func setHoverLink(_ range: Range<Int>?) -> [InteractionEffect] {
    guard range != overlay.hoverLink, let layout else { return [] }
    let rects = [overlay.hoverLink, range].compactMap { $0 }.flatMap { link in
      layout.rects(for: link).map(\.rect)
    }
    overlay.hoverLink = range
    return redraws(rects)
  }

  // MARK: Press, drag, release

  mutating func pressed(at pane: CGPoint, now: UInt64) -> [InteractionEffect] {
    guard let layout, pane.y >= 0, pane.y < geometry.contentHeight else { return [] }
    let page = pagePoint(pane)
    for region in layout.regions where region.maxOffset > 0 {
      guard let bar = RegionScrollbar(region: region, typography: layout.prepared.typography),
        bar.hitArea.contains(page)
      else { continue }
      let onThumb = page.x >= bar.thumb.minX && page.x <= bar.thumb.maxX
      let grab = onThumb ? page.x - bar.thumb.minX : bar.thumb.width / 2
      press = Press(kind: .scrollbar(region.id, grab: grab), start: pane)
      return onThumb ? [] : setRegionOffset(region.id, bar.offset(forThumbMinX: page.x - grab))
    }
    var count = 1
    if let last = clicks, now >= last.time, now - last.time <= timing.multiClickNanoseconds,
      abs(last.point.x - pane.x) <= dragThreshold * 2, abs(last.point.y - pane.y) <= dragThreshold * 2
    {
      count = min(last.count + 1, 3)
    }
    clicks = ClickRecord(time: now, point: pane, count: count)
    let hit = layout.hit(page)
    var target = hit.target
    if case .task = target { target = nil }
    let before = overlay.selection
    press = Press(
      kind: .content(target: target, region: hit.region), start: pane, selectionBefore: before,
      textOffset: hit.target == nil && layout.isOverText(page) ? hit.position?.offset : nil)
    let focusEffects = setFocus(
      clickedFocusable(at: page, target: target, position: hit.position?.offset), fromPointer: true)
    guard let position = hit.position?.offset else { return focusEffects }
    return focusEffects + selectionPress(at: position, count: count, in: layout)
  }

  func clickedFocusable(at page: CGPoint, target: HitTarget?, position: Int?) -> Focusable? {
    guard let layout else { return nil }
    switch target {
    case .link(let href):
      if let position, let link = layout.prepared.links.first(where: { $0.range.contains(position) && $0.href == href })
      {
        return .link(link.range, href: href)
      }
      let videos = Self.videoTargets(in: layout)
      if let index = videos.firstIndex(where: {
        $0.target == .link(href) && layout.displayRect($0.rect, region: $0.region).contains(page)
      }) {
        return .video(index, href: href)
      }
    case .detailsToggle(let id): return .details(id)
    case .copyCode(let id, _): return .codeBlock(id)
    default: break
    }
    if let block = codeBlock(at: page) { return .codeBlock(block) }
    if let region = layout.regions.first(where: { $0.kind == .table && $0.maxOffset > 0 && $0.rect.contains(page) }) {
      return .table(region.id)
    }
    return nil
  }

  mutating func selectionPress(at position: Int, count: Int, in layout: PageLayout) -> [InteractionEffect] {
    switch count {
    case 2:
      granularity = .word
      let word = layout.wordRange(at: position)
      selectionAnchor = word
      press?.selecting = true
      return setSelection(word.isEmpty ? nil : word)
    case 3:
      granularity = .unit
      let unit = layout.unitRange(at: position)
      selectionAnchor = unit
      press?.selecting = true
      return setSelection(unit.isEmpty ? nil : unit)
    default:
      granularity = .character
      selectionAnchor = position..<position
      return setSelection(nil)
    }
  }

  func extended(_ anchor: Range<Int>, to position: Int, in layout: PageLayout) -> Range<Int>? {
    let snap: Range<Int> =
      switch granularity {
      case .character: position..<position
      case .word: layout.wordRange(at: position)
      case .unit: layout.unitRange(at: position)
      }
    let range: Range<Int>
    if position >= anchor.upperBound {
      range = anchor.lowerBound..<max(snap.upperBound, position)
    } else if position < anchor.lowerBound {
      range = min(snap.lowerBound, position)..<anchor.upperBound
    } else {
      range = anchor
    }
    return range.isEmpty ? nil : range
  }

  mutating func dragged(to pane: CGPoint, now: UInt64) -> [InteractionEffect] {
    guard let current = press, let layout else { return [] }
    let page = pagePoint(pane)
    switch current.kind {
    case .scrollbar(let id, let grab):
      guard let region = layout.region(id),
        let bar = RegionScrollbar(region: region, typography: layout.prepared.typography)
      else { return [] }
      return setRegionOffset(id, bar.offset(forThumbMinX: page.x - grab))
    case .content:
      if !current.moved, granularity == .character,
        hypot(pane.x - current.start.x, pane.y - current.start.y) < dragThreshold
      {
        return []
      }
      press?.moved = true
      press?.selecting = true
      let effects = extendSelection(toPane: pane)
      autoScrollDeadline = autoScrollVector(pane) == .zero ? nil : now + timing.autoScrollNanoseconds
      return effects
    }
  }

  mutating func extendSelection(toPane pane: CGPoint) -> [InteractionEffect] {
    guard let layout, let anchor = selectionAnchor,
      let position = layout.textPosition(at: pagePoint(pane))?.offset
    else { return [] }
    return setSelection(extended(anchor, to: position, in: layout))
  }

  func autoScrollVector(_ pane: CGPoint) -> CGVector {
    let row = max(geometry.rowHeight, 1)
    var dy: CGFloat = 0
    if pane.y < row {
      dy = -CGFloat(min(1 + Int((row - pane.y) / row), 4)) * row
    } else if pane.y > geometry.contentHeight - row {
      dy = CGFloat(min(1 + Int((pane.y - (geometry.contentHeight - row)) / row), 4)) * row
    }
    var dx: CGFloat = 0
    if case .content(_, let id?) = press?.kind, let region = layout?.region(id) {
      let zone = min(typography.pixels(em: 1.5), region.rect.width / 4)
      if pane.x < region.rect.minX + zone, region.offset > 0 {
        dx = -regionStep / 2
      } else if pane.x > region.rect.maxX - zone, region.offset < region.maxOffset {
        dx = regionStep / 2
      }
    }
    return CGVector(dx: dx, dy: dy)
  }

  mutating func autoScroll(at now: UInt64) -> [InteractionEffect] {
    autoScrollDeadline = nil
    guard let current = press, current.selecting, let pane = pointer else { return [] }
    let vector = autoScrollVector(pane)
    guard vector != .zero else { return [] }
    var effects: [InteractionEffect] = []
    if vector.dy != 0 { effects += scroll(by: vector.dy) }
    if vector.dx != 0, case .content(_, let id?) = current.kind { effects += scrollRegion(id, by: vector.dx) }
    effects += extendSelection(toPane: pane)
    autoScrollDeadline = now + timing.autoScrollNanoseconds
    return effects
  }

  mutating func released(at now: UInt64) -> [InteractionEffect] {
    guard let current = press else { return [] }
    press = nil
    autoScrollDeadline = nil
    guard case .content(let target, _) = current.kind else { return [] }
    if !current.moved, clicks?.count == 1 {
      if let target { return activate(target, at: now) }
      if let offset = current.textOffset, let link = editorLink, link.syncsLive, link.followsShownFile,
        let layout, let line = clickLine(atText: offset, in: layout)
      {
        return [.jumpEditor(line: line)]
      }
    }
    if current.selecting, let selection = overlay.selection, !selection.isEmpty,
      selection != current.selectionBefore
    {
      copyOnSelect = environment.copyOnSelect()
      if copyOnSelect { return copySelection(markdown: false, at: now) }
    }
    return []
  }

  mutating func activate(_ target: HitTarget, at now: UInt64) -> [InteractionEffect] {
    switch target {
    case .link(let href): return follow(href, at: now)
    case .copyCode(let id, _): return copyCode(id, at: now)
    case .detailsToggle(let id): return toggleDetails(id)
    case .task: return []
    }
  }

  // MARK: Hover

  func codeBlock(at page: CGPoint) -> BlockID? {
    codeFrames.first { $0.value.contains(page) }?.key
  }

  mutating func hovered(at pane: CGPoint) -> [InteractionEffect] {
    var link: String?
    var block: BlockID?
    var linkRange: Range<Int>?
    var shape = PointerShape.default
    if let layout, pane.y >= 0, pane.y < geometry.contentHeight {
      let page = pagePoint(pane)
      let target = layout.target(at: page)
      switch target {
      case .link(let href):
        link = href
        shape = .pointer
        if let position = layout.textPosition(at: page)?.offset {
          linkRange = layout.prepared.links.first { $0.range.contains(position) && $0.href == href }?.range
        }
      case .copyCode, .detailsToggle: shape = .pointer
      case .task, nil: shape = layout.isOverText(page) ? .text : .default
      }
      block = codeBlock(at: page)
    }
    var effects = setPointerShape(shape) + setHoverLink(linkRange)
    if link != hoverLink {
      hoverLink = link
      effects.append(.redrawStatusBar)
    }
    if block != hoverCodeBlock {
      let old = hoverCodeBlock
      hoverCodeBlock = block
      if copiedUntil == nil {
        overlay.copyButton = block.map { CopyButtonOverlay(block: $0) }
        effects += [old, block].compactMap { $0 }.flatMap { redrawCopyButton($0) }
      }
    }
    return effects
  }

  func redrawCopyButton(_ id: BlockID) -> [InteractionEffect] {
    guard let layout,
      let rect = layout.targets.first(where: {
        if case .copyCode(id, _) = $0.target { return true }
        return false
      })?.rect
    else { return [] }
    let pad = layout.prepared.typography.pixels(em: 0.25)
    return [.redraw(rect.insetBy(dx: -pad, dy: -pad))]
  }

  // MARK: Selection

  mutating func setSelection(_ range: Range<Int>?) -> [InteractionEffect] {
    let old = overlay.selection
    guard old != range else { return [] }
    overlay.selection = range
    if range == nil, press == nil { selectionAnchor = nil }
    guard let layout else { return [] }
    var changed: [Range<Int>] = []
    switch (old, range) {
    case (let old?, let new?):
      changed = [
        min(old.lowerBound, new.lowerBound)..<max(old.lowerBound, new.lowerBound),
        min(old.upperBound, new.upperBound)..<max(old.upperBound, new.upperBound),
      ]
    case (let only?, nil), (nil, let only?):
      changed = [only]
    case (nil, nil):
      break
    }
    var rects: [CGRect] = []
    for part in changed where !part.isEmpty {
      let extended = part.lowerBound..<min(part.upperBound + 1, layout.prepared.text.length)
      rects += layout.rects(for: extended.isEmpty ? part : extended).map(\.rect)
    }
    return bands(rects).map { .redraw($0) }
  }

  func bands(_ rects: [CGRect]) -> [CGRect] {
    var merged: [CGRect] = []
    for rect in rects.sorted(by: { $0.minY < $1.minY }) {
      let band = CGRect(x: 0, y: rect.minY, width: geometry.width, height: rect.height)
      if let last = merged.last, band.minY <= last.maxY + 1 {
        merged[merged.count - 1] = last.union(band)
      } else {
        merged.append(band)
      }
    }
    return merged
  }

  mutating func selectAll() -> [InteractionEffect] {
    guard let length = layout?.prepared.text.length, length > 0 else { return [] }
    selectionAnchor = 0..<0
    granularity = .character
    return setSelection(0..<length)
  }

  // MARK: Copy

  mutating func copySelection(markdown: Bool, at now: UInt64) -> [InteractionEffect] {
    guard let layout, let selection = overlay.selection, !selection.isEmpty else {
      return show("Nothing selected", kind: .info, at: now)
    }
    return copy(markdown ? layout.markdown(selection) : layout.plainText(selection), markdown: markdown, at: now)
  }

  mutating func copyCode(_ id: BlockID, at now: UInt64) -> [InteractionEffect] {
    guard var code = layout?.prepared.codeBlocks[id]?.code else { return [] }
    if code.hasSuffix("\n") { code.removeLast() }
    var effects = copy(code, at: now)
    guard effects.contains(where: { if case .writeClipboard = $0 { true } else { false } }) else { return effects }
    let previous = overlay.copyButton?.block
    overlay.copyButton = CopyButtonOverlay(block: id, copied: true)
    copiedUntil = now + timing.copiedNanoseconds
    if let previous, previous != id { effects += redrawCopyButton(previous) }
    effects += redrawCopyButton(id)
    return effects
  }

  mutating func copy(_ text: String, markdown: Bool = false, at now: UInt64) -> [InteractionEffect] {
    guard !text.isEmpty else { return show("Nothing to copy", kind: .info, at: now) }
    return [.writeClipboard(text, markdown: markdown)]
      + show("Copied \(text.count) characters", kind: .success, at: now)
  }

  // MARK: Regions

  mutating func scrollRegion(_ id: BlockID, by delta: CGFloat) -> [InteractionEffect] {
    guard let region = layout?.region(id) else { return [] }
    return setRegionOffset(id, region.offset + delta)
  }

  mutating func setRegionOffset(_ id: BlockID, _ value: CGFloat) -> [InteractionEffect] {
    guard let layout, let region = layout.region(id) else { return [] }
    let updated = layout.settingScrollOffset(value, for: id)
    guard updated.region(id)?.offset != region.offset else { return [] }
    self.layout = updated
    if let span = regionRanges[id] {
      for index in overlay.findMatches.indices where overlay.findMatches[index].range.overlaps(span) {
        let range = overlay.findMatches[index].range
        if updated.hiddenRanges.contains(where: { $0.overlaps(range) }) { continue }
        overlay.findMatches[index].rects = updated.rects(for: range)
      }
    }
    return [.regionScrolled(id, offset: updated.region(id)?.offset ?? 0), .redraw(region.rect)]
  }

  mutating func revealHorizontally(_ range: Range<Int>, in id: BlockID) -> [InteractionEffect] {
    guard let layout, let region = layout.region(id), region.maxOffset > 0,
      let rect = layout.rects(for: range, scrolled: false).first(where: { $0.region == id })?.rect
    else { return [] }
    let pad = layout.prepared.typography.pixels(em: 1)
    let visibleMin = region.rect.minX + pad
    let visibleMax = region.rect.maxX - pad
    var target = region.offset
    if rect.minX - target < visibleMin {
      target = rect.minX - visibleMin
    } else if rect.maxX - target > visibleMax {
      target = min(rect.maxX - visibleMax, rect.minX - visibleMin)
    }
    return setRegionOffset(id, target)
  }

  // MARK: Details

  func queuedExpandedDetails(in layout: PageLayout) -> Set<BlockID> {
    guard let pending = pendingRequest else { return layout.expandedDetails }
    if let carried = pending.carriedDetails {
      return Set(BlockIdentity.details(in: layout.prepared).filter { carried.expanded.contains($0.value) }.keys)
    }
    return pending.expandedDetails ?? layout.expandedDetails
  }

  mutating func toggleDetails(_ id: BlockID) -> [InteractionEffect] {
    guard let layout else { return [] }
    var expanded = queuedExpandedDetails(in: layout)
    if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    var anchor = topAnchor(ratio: 1)
    if let area = layout.targets.first(where: { $0.target == .detailsToggle(id) }),
      let summary = layout.fragments.filter({
        area.rect.intersects(
          CGRect(
            x: $0.minX, y: $0.lineTop, width: max($0.maxX - $0.minX, 1), height: $0.lineBottom - $0.lineTop))
      })
      .min(by: { $0.lineTop < $1.lineTop || ($0.lineTop == $1.lineTop && $0.range.lowerBound < $1.range.lowerBound) })
    {
      anchor = .text(offset: summary.range.lowerBound, delta: offset - summary.lineTop, ratio: 1)
    }
    return requestLayout(expanded: .some(expanded), anchor: anchor)
  }

  // MARK: Links and history

  mutating func follow(_ href: String, at now: UInt64) -> [InteractionEffect] {
    guard let file else { return [] }
    switch linkAction(href: href, currentFile: file, fileExists: environment.fileExists) {
    case .scrollToAnchor(let name):
      return jump(toAnchor: name, at: now)
    case .openMarkdown(let url, let fragment):
      if url.standardizedFileURL.path == file.standardizedFileURL.path {
        return fragment.map { jump(toAnchor: $0, at: now) } ?? []
      }
      pendingNavigation = .link(url, from: History.Entry(file: file, offset: offset), fragment: fragment)
      return [.loadDocument(url)]
    case .openExternal(let url):
      if url.isFileURL, !environment.isSafeToOpenLocally(url) {
        return show("Not opening \(url.lastPathComponent)", kind: .error, at: now)
      }
      if !environment.openURL(url) {
        return show("Could not open \(url.absoluteString)", kind: .error, at: now)
      }
      return []
    case .ignore:
      return show("Cannot open \(href)", kind: .error, at: now)
    }
  }

  mutating func jump(toAnchor name: String, at now: UInt64) -> [InteractionEffect] {
    guard let layout, let file else { return [] }
    guard let position = layout.anchorPosition(name) else {
      return show("No anchor #\(name)", kind: .error, at: now)
    }
    history.push(History.Entry(file: file, offset: offset))
    if !position.collapsedDetails.isEmpty {
      return requestLayout(
        expanded: .some(queuedExpandedDetails(in: layout).union(position.collapsedDetails)), anchor: .fragment(name))
    }
    return setOffset(position.y)
  }

  public mutating func open(_ url: URL) -> [InteractionEffect] {
    if let file, url.standardizedFileURL.path == file.standardizedFileURL.path { return [.reload] }
    pendingNavigation = .link(url, from: file.map { History.Entry(file: $0, offset: offset) }, fragment: nil)
    return [.loadDocument(url)]
  }

  mutating func goBack(at now: UInt64) -> [InteractionEffect] {
    guard let file else { return [] }
    let current = History.Entry(file: file, offset: offset)
    guard let entry = history.back(from: current) else { return show("No previous page", kind: .info, at: now) }
    return navigate(to: entry, current: current, back: true)
  }

  mutating func goForward(at now: UInt64) -> [InteractionEffect] {
    guard let file else { return [] }
    let current = History.Entry(file: file, offset: offset)
    guard let entry = history.forward(from: current) else { return show("No next page", kind: .info, at: now) }
    return navigate(to: entry, current: current, back: false)
  }

  mutating func navigate(to entry: History.Entry, current: History.Entry, back: Bool) -> [InteractionEffect] {
    if entry.file.standardizedFileURL.path == current.file.standardizedFileURL.path {
      return setOffset(entry.offset)
    }
    pendingNavigation =
      back ? .back(entry.file, entry: entry, current: current) : .forward(entry.file, entry: entry, current: current)
    return [.loadDocument(entry.file)]
  }
}
