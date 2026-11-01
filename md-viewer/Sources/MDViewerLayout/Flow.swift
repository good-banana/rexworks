import CoreGraphics
import Foundation
import MDViewerDocument

struct LineItem {
  enum Kind {
    case segment(Int)
    case piece(Int, Range<Int>, start: CGFloat, width: CGFloat)
    case image(Int, CGSize, intrinsic: Bool)
    case anchor(String)
  }

  var kind: Kind
  var x: CGFloat
}

struct LineBuffer {
  var items: [LineItem] = []
  var cursor: CGFloat = 0
  var visibleEnd: CGFloat = 0
  var emitted = false
}

extension LayoutEngine {
  mutating func flow(_ run: Run, x: CGFloat, width: CGFloat, y: inout CGFloat, alignment: TextAlignment?) {
    var buffer = LineBuffer()
    for word in run.words {
      if word.isHardBreak {
        emitLine(&buffer, run: run, x: x, width: width, y: &y, alignment: alignment)
        continue
      }
      if let image = word.image {
        let (size, intrinsic) = imageSize(image, maxWidth: width)
        if buffer.cursor > 0, buffer.cursor + size.width > width {
          emitLine(&buffer, run: run, x: x, width: width, y: &y, alignment: alignment)
        }
        buffer.items.append(LineItem(kind: .image(image, size, intrinsic: intrinsic), x: buffer.cursor))
        buffer.cursor += size.width
        buffer.visibleEnd = buffer.cursor
        continue
      }
      if buffer.cursor > 0, buffer.cursor + word.visible > width {
        emitLine(&buffer, run: run, x: x, width: width, y: &y, alignment: alignment)
      }
      if word.visible > width {
        split(word, run: run, buffer: &buffer, x: x, width: width, y: &y, alignment: alignment)
        continue
      }
      for index in word.atoms {
        append(run.atoms[index], to: &buffer)
      }
    }
    if !buffer.items.isEmpty || !buffer.emitted {
      emitLine(&buffer, run: run, x: x, width: width, y: &y, alignment: alignment)
    }
  }

  private func append(_ atom: Atom, to buffer: inout LineBuffer) {
    switch atom {
    case .segment(let id):
      let segment = prepared.segments[id]
      buffer.items.append(LineItem(kind: .segment(id), x: buffer.cursor))
      buffer.visibleEnd = max(buffer.visibleEnd, buffer.cursor + segment.visibleAdvance)
      buffer.cursor += segment.advance
    case .anchor(let name):
      buffer.items.append(LineItem(kind: .anchor(name), x: buffer.cursor))
    case .image, .hardBreak:
      break
    }
  }

  private mutating func split(
    _ word: Word, run: Run, buffer: inout LineBuffer, x: CGFloat, width: CGFloat, y: inout CGFloat,
    alignment: TextAlignment?
  ) {
    for index in word.atoms {
      guard case .segment(let id) = run.atoms[index] else {
        append(run.atoms[index], to: &buffer)
        continue
      }
      let segment = prepared.segments[id]
      if buffer.cursor + segment.visibleAdvance <= width {
        append(run.atoms[index], to: &buffer)
        continue
      }
      let boundaries = graphemeBoundaries(segment.range)
      let allCarets = segment.caretOffsets()
      let carets = boundaries.map { allCarets[$0 - segment.range.lowerBound] }
      let last = boundaries.count - 1
      var startIndex = 0
      while startIndex < last {
        let start = boundaries[startIndex]
        let lead = start == segment.range.lowerBound ? segment.leadingPad : 0
        let available = width - buffer.cursor - lead
        let origin = carets[startIndex]
        func span(_ end: Int) -> CGFloat { abs(carets[end] - origin) }
        if span(last) - segment.trailingWhitespace <= available {
          buffer.items.append(
            LineItem(
              kind: .piece(id, start..<segment.range.upperBound, start: min(origin, carets[last]), width: span(last)),
              x: buffer.cursor + lead))
          buffer.visibleEnd = buffer.cursor + lead + span(last) - segment.trailingWhitespace + segment.trailingPad
          buffer.cursor += lead + span(last) + segment.trailingPad
          break
        }
        var endIndex = startIndex
        var low = startIndex + 1
        var high = last
        while low <= high {
          let mid = (low + high) / 2
          if span(mid) <= available {
            endIndex = mid
            low = mid + 1
          } else {
            high = mid - 1
          }
        }
        if endIndex == startIndex {
          if buffer.cursor > 0 {
            emitLine(&buffer, run: run, x: x, width: width, y: &y, alignment: alignment)
            continue
          }
          endIndex = startIndex + 1
        }
        buffer.items.append(
          LineItem(
            kind: .piece(
              id, start..<boundaries[endIndex], start: min(origin, carets[endIndex]), width: span(endIndex)),
            x: buffer.cursor + lead))
        buffer.cursor += lead + span(endIndex)
        buffer.visibleEnd = buffer.cursor
        emitLine(&buffer, run: run, x: x, width: width, y: &y, alignment: alignment)
        startIndex = endIndex
      }
    }
  }

  private func graphemeBoundaries(_ range: Range<Int>) -> [Int] {
    let text = prepared.text
    var boundaries = [range.lowerBound]
    var position = range.lowerBound
    while position < range.upperBound {
      let composed = text.rangeOfComposedCharacterSequence(at: position)
      position = min(max(composed.location + composed.length, position + 1), range.upperBound)
      boundaries.append(position)
    }
    return boundaries
  }

  private func reorder(_ buffer: inout LineBuffer, baseLevel: Int) {
    let count = buffer.items.count
    guard count > 1 else { return }
    var advances = [CGFloat](repeating: 0, count: count)
    var levels = [Int](repeating: baseLevel, count: count)
    for index in 0..<count {
      let next = index + 1 < count ? buffer.items[index + 1].x : buffer.cursor
      advances[index] = next - buffer.items[index].x
      switch buffer.items[index].kind {
      case .segment(let id), .piece(let id, _, _, _):
        levels[index] = prepared.segments[id].bidiLevel
      case .image:
        levels[index] = baseLevel
      case .anchor:
        levels[index] = index > 0 ? levels[index - 1] : baseLevel
      }
    }
    var order = Array(0..<count)
    var level = levels.max() ?? 0
    while level >= 1 {
      var start = 0
      while start < count {
        guard levels[order[start]] >= level else {
          start += 1
          continue
        }
        var end = start
        while end < count, levels[order[end]] >= level { end += 1 }
        order[start..<end].reverse()
        start = end
      }
      level -= 1
    }
    var position: CGFloat = 0
    for index in order {
      buffer.items[index].x = position
      position += advances[index]
    }
  }

  private mutating func emitLine(
    _ buffer: inout LineBuffer, run: Run, x: CGFloat, width: CGFloat, y: inout CGFloat, alignment: TextAlignment?
  ) {
    var above = run.strutAbove
    var below = run.strutBelow
    for item in buffer.items {
      switch item.kind {
      case .segment(let id), .piece(let id, _, _, _):
        let segment = prepared.segments[id]
        guard segment.affectsLineHeight else { continue }
        above = max(above, segment.above)
        below = max(below, segment.below)
      case .image(_, let size, _):
        above = max(above, size.height)
      case .anchor:
        continue
      }
    }
    let top = y
    let baseline = top + above
    let bottom = baseline + below
    let needsReorder =
      run.isRightToLeft
      || buffer.items.contains {
        switch $0.kind {
        case .segment(let id), .piece(let id, _, _, _): prepared.segments[id].bidiLevel > 0
        default: false
        }
      }
    if needsReorder { reorder(&buffer, baseLevel: run.isRightToLeft ? 1 : 0) }
    let hang = max(buffer.cursor - buffer.visibleEnd, 0)
    let extentLeft: CGFloat = run.isRightToLeft ? hang : 0
    let extentRight: CGFloat = run.isRightToLeft ? buffer.cursor : buffer.visibleEnd
    let slack = max(width - (extentRight - extentLeft), 0)
    let shift: CGFloat =
      switch alignment ?? (run.isRightToLeft ? .right : .left) {
      case .center: (slack / 2).rounded() - extentLeft
      case .right: slack - extentLeft
      case .left, .justify: -extentLeft
      }
    var boxes: [(group: Int, kind: InlineBoxKind, rect: CGRect)] = []
    for item in buffer.items {
      let left = x + shift + item.x
      switch item.kind {
      case .segment(let id), .piece(let id, _, _, _):
        let segment = prepared.segments[id]
        var range = segment.range
        var origin = CGPoint(x: left + segment.leadingPad + segment.drawOffset, y: baseline + segment.baselineShift)
        var minX = left + segment.leadingPad
        var maxX = minX + segment.width
        var clipped = false
        var boxRight = left + segment.advance
        if case .piece(_, let pieceRange, let start, let pieceWidth) = item.kind {
          range = pieceRange
          origin.x = left - start
          minX = left
          maxX = left + pieceWidth
          clipped = true
          boxRight = maxX + (pieceRange.upperBound == segment.range.upperBound ? segment.trailingPad : 0)
        }
        out.fragments.append(
          TextFragment(
            segment: id, range: range, origin: origin, minX: minX, maxX: maxX, lineTop: top, lineBottom: bottom,
            region: nil, isClipped: clipped))
        if let group = segment.boxGroup {
          let rect = CGRect(
            x: clipped && range.lowerBound != segment.range.lowerBound ? minX : left,
            y: origin.y - segment.ascent - segment.boxVerticalPad,
            width: 0, height: segment.ascent + segment.descent + segment.boxVerticalPad * 2)
          let extended = CGRect(x: rect.minX, y: rect.minY, width: boxRight - rect.minX, height: rect.height)
          if let last = boxes.last, last.group == group {
            boxes[boxes.count - 1].rect = last.rect.union(extended)
          } else {
            boxes.append((group, segment.style.box ?? .code, extended))
          }
        }
      case .image(let index, let size, let intrinsic):
        let atom = prepared.images[index]
        out.images.append(
          ImageBox(
            rect: CGRect(x: left, y: baseline - size.height, width: size.width, height: size.height),
            content: .image(source: chosenSource(atom.image)), alt: atom.image.alt, link: atom.link,
            hasIntrinsicSize: intrinsic, region: nil, block: atom.block))
      case .anchor(let name):
        out.anchors.append((name, top))
      }
    }
    let radius = typography.pixels(em: typography.cornerRadius)
    for box in boxes {
      out.decorations.append(
        Decoration(
          rect: box.rect, kind: .inlineBox(box.kind), region: nil, cornerRadius: box.kind == .mark ? 0 : radius))
    }
    y = bottom
    buffer = LineBuffer(items: [], cursor: 0, visibleEnd: 0, emitted: true)
  }

  func chosenSource(_ image: Image) -> String {
    let wanted: ColorScheme = input.prefersDark ? .dark : .light
    if let match = image.sources.first(where: {
      $0.colorScheme == wanted || ($0.colorScheme == nil && $0.media.isEmpty)
    }) {
      return match.source
    }
    return image.source.isEmpty ? image.sources.first?.source ?? "" : image.source
  }

  func imageSize(_ index: Int, maxWidth: CGFloat) -> (size: CGSize, intrinsic: Bool) {
    let image = prepared.images[index].image
    let provided = input.imageSize(chosenSource(image))
    var width = image.width.map { CGFloat($0) }
    var height = image.height.map { CGFloat($0) }
    if width == nil, height == nil, let provided {
      width = provided.width
      height = provided.height
    } else if width == nil, let known = height, let provided, provided.height > 0 {
      width = known * provided.width / provided.height
    } else if height == nil, let known = width, let provided, provided.width > 0 {
      height = known * provided.height / provided.width
    }
    let intrinsic = width != nil && height != nil
    var size: CGSize
    if let width, let height {
      size = CGSize(width: typography.pixels(cssPoints: width), height: typography.pixels(cssPoints: height))
    } else if let side = width ?? height {
      size = CGSize(width: typography.pixels(cssPoints: side), height: typography.pixels(cssPoints: side))
    } else {
      size = CGSize(
        width: typography.pixels(em: typography.imagePlaceholderSize.width),
        height: typography.pixels(em: typography.imagePlaceholderSize.height))
    }
    if size.width > maxWidth, size.width > 0 {
      size = CGSize(width: maxWidth, height: size.height * maxWidth / size.width)
    }
    return (size, intrinsic)
  }
}
