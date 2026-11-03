import CoreGraphics
import MDViewerCore
import MDViewerRender

public final class RasterFrameSource: FrameSource {
  public var rasterizer: Rasterizer
  public var overlay: RenderOverlay
  public var status: StatusBarContent?
  public var showsHelp = false
  public var editMode = EditMode.split
  public var editorPicker: EditorPickerContent?

  public init(rasterizer: Rasterizer, overlay: RenderOverlay = RenderOverlay(), status: StatusBarContent? = nil) {
    self.rasterizer = rasterizer
    self.overlay = overlay
    self.status = status
  }

  public func drawFrame(_ viewport: DisplayViewport, into bitmap: RasterBitmap) {
    drawPatch(viewport.frameRect, viewport: viewport, into: bitmap)
  }

  public func drawPatch(_ rect: PixelRect, viewport: DisplayViewport, into bitmap: RasterBitmap) {
    if let content = rect.intersection(viewport.contentRect) {
      rasterizer.draw(
        viewport.pageRect(fromPane: content), into: bitmap,
        at: CGPoint(x: content.x - rect.x, y: content.y - rect.y), overlay: overlay)
      let backingScale = rasterizer.layout.prepared.typography.backingScale
      let origin = CGPoint(x: rect.x, y: rect.y)
      if showsHelp {
        HelpOverlay(palette: rasterizer.palette, backingScale: backingScale, editMode: editMode).draw(
          in: viewport.contentRect.cgRect, clip: content.cgRect, origin: origin, bitmap: bitmap)
      }
      if let editorPicker {
        EditorPicker(content: editorPicker, backingScale: backingScale).draw(
          palette: rasterizer.palette, in: viewport.contentRect.cgRect, clip: content.cgRect, origin: origin,
          bitmap: bitmap)
      }
    }
    guard rect.intersection(viewport.statusBarRect) != nil else { return }
    let bar = viewport.statusBarRect.cgRect.offsetBy(dx: CGFloat(-rect.x), dy: CGFloat(-rect.y))
    let backingScale = rasterizer.layout.prepared.typography.backingScale
    guard var status else {
      let context = bitmap.context
      context.setFillColor(rasterizer.palette.statusBarBackground.cgColor)
      context.fill(CGRect(x: bar.minX, y: CGFloat(bitmap.height) - bar.maxY, width: bar.width, height: bar.height))
      return
    }
    let progress = viewport.progress
    status.progress = ScrollProgress(start: progress.start, fraction: progress.fraction)
    StatusBar(palette: rasterizer.palette, backingScale: backingScale).draw(status, in: bar, bitmap: bitmap)
  }
}
