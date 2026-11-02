import CoreGraphics
import MDViewerCore
import MDViewerLayout
import XCTest

@testable import MDViewerRender

final class VideoBadgeTests: XCTestCase {
  func testVideosDrawAPlayBadgeOverThePosterOrPlaceholder() throws {
    let palette = RenderPalette.fallback(dark: true)
    let prepared = prepare("<video src=\"clip.mp4\"></video>\n\n![still](still.png)")
    let page = prepared.layout(
      LayoutInput(width: 1200, imageSize: { $0 == "still.png" ? CGSize(width: 320, height: 180) : nil }))
    let video = try XCTUnwrap(page.images.first { $0.video != nil })
    let still = try XCTUnwrap(page.images.first { $0.video == nil })
    let poster = solid(RGB(0.2, 0.6, 0.2))
    let rasterizer = Rasterizer(
      layout: page, palette: palette, assets: RenderAssets(image: { $0 == "still.png" ? poster : nil }))
    let bitmap = try XCTUnwrap(rasterizer.render(CGRect(x: 0, y: 0, width: page.width, height: page.height)))
    let center = CGPoint(x: video.rect.midX, y: video.rect.midY)
    assertColor(bitmap.pixel(center), RGB(1, 1, 1), tolerance: 10, "the triangle is white")
    let ring = CGPoint(x: video.rect.midX - min(video.rect.width, video.rect.height) * 0.13, y: video.rect.midY)
    let dark = try XCTUnwrap(bitmap.pixel(ring))
    XCTAssertLessThan(Int(dark.r) + Int(dark.g) + Int(dark.b), 3 * 80, "the badge circle is dark")
    assertColor(
      bitmap.pixel(CGPoint(x: still.rect.midX, y: still.rect.midY)), RGB(0.2, 0.6, 0.2), tolerance: 6,
      "plain images get no badge")
  }

  private func solid(_ color: RGB) -> CGImage {
    let context = CGContext(
      data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    return context.makeImage()!
  }
}
