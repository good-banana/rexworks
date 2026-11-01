import CoreGraphics
import MDViewerCore
import MDViewerLayout

struct ScrollChrome {
  let painter: Painter

  func draw(_ region: ScrollRegion) {
    let context = painter.context
    let colors = painter.colors
    let background: RGB
    let radius: CGFloat
    switch region.kind {
    case .codeBlock:
      background = colors.palette.codeBlockBackground
      radius = painter.em(painter.typography.cornerRadius)
    case .table:
      background = colors.palette.pageBackground
      radius = 0
    }
    context.saveGState()
    defer { context.restoreGState() }
    context.addPath(CGPath(roundedRect: region.rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()

    let fade = min(painter.em(1.5), region.rect.width / 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
    let solid = background.cgColor
    let clear = background.cgColor(alpha: 0)
    if region.offset > 0.5,
      let gradient = CGGradient(colorsSpace: space, colors: [solid, clear] as CFArray, locations: [0, 1])
    {
      context.drawLinearGradient(
        gradient, start: CGPoint(x: region.rect.minX, y: 0), end: CGPoint(x: region.rect.minX + fade, y: 0),
        options: [])
    }
    if region.offset < region.maxOffset - 0.5,
      let gradient = CGGradient(colorsSpace: space, colors: [clear, solid] as CFArray, locations: [0, 1])
    {
      context.drawLinearGradient(
        gradient, start: CGPoint(x: region.rect.maxX - fade, y: 0), end: CGPoint(x: region.rect.maxX, y: 0),
        options: [])
    }

    let inset = painter.em(0.5)
    let track = region.rect.width - inset * 2
    guard track > 0, region.contentWidth > 0 else { return }
    let height = max(painter.hairline * 2, painter.css(3).rounded())
    let width = min(max(painter.css(24), track * region.rect.width / region.contentWidth), track)
    let progress = region.maxOffset > 0 ? min(max(region.offset / region.maxOffset, 0), 1) : 0
    let thumb = CGRect(
      x: region.rect.minX + inset + (track - width) * progress, y: region.rect.maxY - height - painter.css(3),
      width: width, height: height)
    painter.fill(thumb, colors.faded(\.mutedText, 0.55), radius: height / 2)
  }
}
