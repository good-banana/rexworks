import CoreGraphics
import MDViewerDocument

struct Glyphs {
  let context: CGContext
  let hairline: CGFloat

  private func strokeStyle(_ color: CGColor, width: CGFloat) {
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
  }

  private func point(_ rect: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
  }

  private func exclamation(_ rect: CGRect, top: CGFloat, bottom: CGFloat, dot: CGFloat, width: CGFloat) {
    context.move(to: point(rect, 0.5, top))
    context.addLine(to: point(rect, 0.5, bottom))
    context.strokePath()
    let center = point(rect, 0.5, dot)
    let radius = width * 0.7
    context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
  }

  func alertIcon(_ kind: AlertKind, in rect: CGRect, color: CGColor) {
    context.saveGState()
    defer { context.restoreGState() }
    let width = max(hairline * 1.5, rect.width * 0.09)
    strokeStyle(color, width: width)
    context.setFillColor(color)
    let inner = rect.insetBy(dx: width / 2, dy: width / 2)
    switch kind {
    case .note:
      context.strokeEllipse(in: inner)
      context.move(to: point(rect, 0.5, 0.46))
      context.addLine(to: point(rect, 0.5, 0.72))
      context.strokePath()
      let center = point(rect, 0.5, 0.3)
      let radius = width * 0.7
      context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    case .tip:
      let bulb = CGRect(
        x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.04, width: rect.width * 0.6,
        height: rect.height * 0.6)
      context.addArc(
        center: CGPoint(x: bulb.midX, y: bulb.midY), radius: bulb.width / 2, startAngle: .pi * 0.75,
        endAngle: .pi * 0.25, clockwise: false)
      context.addLine(to: point(rect, 0.62, 0.72))
      context.addLine(to: point(rect, 0.38, 0.72))
      context.closePath()
      context.strokePath()
      context.move(to: point(rect, 0.4, 0.88))
      context.addLine(to: point(rect, 0.6, 0.88))
      context.strokePath()
    case .important:
      let bubble = CGRect(
        x: inner.minX, y: inner.minY + rect.height * 0.04, width: inner.width, height: rect.height * 0.66)
      let radius = rect.width * 0.14
      context.addPath(CGPath(roundedRect: bubble, cornerWidth: radius, cornerHeight: radius, transform: nil))
      context.strokePath()
      context.move(to: CGPoint(x: bubble.minX + rect.width * 0.22, y: bubble.maxY))
      context.addLine(to: CGPoint(x: bubble.minX + rect.width * 0.22, y: inner.maxY))
      context.addLine(to: CGPoint(x: bubble.minX + rect.width * 0.44, y: bubble.maxY))
      context.strokePath()
      exclamation(rect, top: 0.22, bottom: 0.42, dot: 0.56, width: width)
    case .warning:
      context.move(to: point(rect, 0.5, 0.08))
      context.addLine(to: CGPoint(x: inner.maxX, y: rect.minY + rect.height * 0.9))
      context.addLine(to: CGPoint(x: inner.minX, y: rect.minY + rect.height * 0.9))
      context.closePath()
      context.strokePath()
      exclamation(rect, top: 0.4, bottom: 0.6, dot: 0.75, width: width)
    case .caution:
      let center = CGPoint(x: rect.midX, y: rect.midY)
      let radius = inner.width / 2 / cos(.pi / 8)
      for vertex in 0..<8 {
        let angle = CGFloat(vertex) * .pi / 4 + .pi / 8
        let corner = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        if vertex == 0 { context.move(to: corner) } else { context.addLine(to: corner) }
      }
      context.closePath()
      context.strokePath()
      exclamation(rect, top: 0.26, bottom: 0.54, dot: 0.72, width: width)
    }
  }

  func taskBox(
    _ rect: CGRect, checked: Bool, radius: CGFloat, fill: CGColor, mark: CGColor, outline: CGColor,
    background: CGColor
  ) {
    context.saveGState()
    defer { context.restoreGState() }
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if checked {
      context.setFillColor(fill)
      context.addPath(path)
      context.fillPath()
      check(in: rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12), color: mark)
    } else {
      context.setFillColor(background)
      context.addPath(path)
      context.fillPath()
      let width = max(hairline, rect.width * 0.08)
      let inset = rect.insetBy(dx: width / 2, dy: width / 2)
      let innerRadius = max(radius - width / 2, 0)
      strokeStyle(outline, width: width)
      context.addPath(CGPath(roundedRect: inset, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
      context.strokePath()
    }
  }

  func check(in rect: CGRect, color: CGColor) {
    context.saveGState()
    defer { context.restoreGState() }
    strokeStyle(color, width: max(hairline * 1.5, rect.width * 0.14))
    context.move(to: point(rect, 0.16, 0.54))
    context.addLine(to: point(rect, 0.42, 0.78))
    context.addLine(to: point(rect, 0.86, 0.26))
    context.strokePath()
  }

  func copy(in rect: CGRect, color: CGColor) {
    context.saveGState()
    defer { context.restoreGState() }
    let width = max(hairline, rect.width * 0.1)
    strokeStyle(color, width: width)
    let side = rect.width * 0.62
    let radius = rect.width * 0.12
    let back = CGRect(x: rect.minX + width / 2, y: rect.minY + width / 2, width: side, height: side)
    let front = CGRect(x: rect.maxX - side - width / 2, y: rect.maxY - side - width / 2, width: side, height: side)
    context.move(to: CGPoint(x: back.minX, y: front.minY - width))
    context.addLine(to: CGPoint(x: back.minX, y: back.minY + radius))
    context.addArc(
      tangent1End: CGPoint(x: back.minX, y: back.minY), tangent2End: CGPoint(x: back.maxX, y: back.minY), radius: radius
    )
    context.addLine(to: CGPoint(x: front.minX - width, y: back.minY))
    context.strokePath()
    context.addPath(CGPath(roundedRect: front, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.strokePath()
  }

  func disclosure(_ rect: CGRect, expanded: Bool, color: CGColor) {
    context.saveGState()
    defer { context.restoreGState() }
    context.setFillColor(color)
    let side = min(rect.width, rect.height)
    let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    let depth = side * 0.866
    if expanded {
      let top = box.midY - depth / 2
      context.move(to: CGPoint(x: box.minX, y: top))
      context.addLine(to: CGPoint(x: box.maxX, y: top))
      context.addLine(to: CGPoint(x: box.midX, y: top + depth))
    } else {
      let left = box.midX - depth / 2
      context.move(to: CGPoint(x: left, y: box.minY))
      context.addLine(to: CGPoint(x: left + depth, y: box.midY))
      context.addLine(to: CGPoint(x: left, y: box.maxY))
    }
    context.closePath()
    context.fillPath()
  }

  func picture(in rect: CGRect, color: CGColor) {
    let side = min(rect.width, rect.height) * 0.6
    guard side >= hairline * 6 else { return }
    let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side * 0.8)
    context.saveGState()
    defer { context.restoreGState() }
    let width = max(hairline, side * 0.07)
    strokeStyle(color, width: width)
    context.addPath(CGPath(roundedRect: box, cornerWidth: side * 0.1, cornerHeight: side * 0.1, transform: nil))
    context.strokePath()
    context.move(to: point(box, 0.1, 0.85))
    context.addLine(to: point(box, 0.4, 0.5))
    context.addLine(to: point(box, 0.6, 0.7))
    context.addLine(to: point(box, 0.72, 0.58))
    context.addLine(to: point(box, 0.9, 0.85))
    context.strokePath()
    let sun = point(box, 0.7, 0.3)
    let radius = side * 0.08
    context.setFillColor(color)
    context.fillEllipse(in: CGRect(x: sun.x - radius, y: sun.y - radius, width: radius * 2, height: radius * 2))
  }

  func magnifier(in rect: CGRect, color: CGColor) {
    context.saveGState()
    defer { context.restoreGState() }
    let width = max(hairline, rect.width * 0.12)
    strokeStyle(color, width: width)
    let lens = CGRect(
      x: rect.minX + width / 2, y: rect.minY + width / 2, width: rect.width * 0.62, height: rect.height * 0.62)
    context.strokeEllipse(in: lens)
    context.move(to: CGPoint(x: lens.maxX - lens.width * 0.12, y: lens.maxY - lens.height * 0.12))
    context.addLine(to: CGPoint(x: rect.maxX - width / 2, y: rect.maxY - width / 2))
    context.strokePath()
  }
}
