import CoreGraphics
import MDViewerDocument
import XCTest

@testable import MDViewerLayout

final class VideoLayoutTests: XCTestCase {
  func testVideosLayOutAsSixteenByNinePlaceholdersThatLink() throws {
    let page = layout("<video src=\"clip.mp4\"></video>\n\n<video src=\"b.mov\" width=\"320\"></video>")
    XCTAssertEqual(page.images.count, 2)
    let first = page.images[0]
    XCTAssertEqual(first.video, "clip.mp4")
    XCTAssertEqual(first.link, "clip.mp4")
    XCTAssertEqual(first.content, .image(source: "clip.mp4"), "without a poster the frame comes from the video")
    XCTAssertFalse(first.hasIntrinsicSize)
    XCTAssertEqual(first.rect.width / first.rect.height, 16.0 / 9.0, accuracy: 0.01)
    XCTAssertEqual(page.images[1].rect.width, page.prepared.typography.pixels(cssPoints: 320))
    XCTAssertEqual(page.images[1].rect.width / page.images[1].rect.height, 16.0 / 9.0, accuracy: 0.01)
    XCTAssertEqual(page.target(at: CGPoint(x: first.rect.midX, y: first.rect.midY)), .link("clip.mp4"))
    XCTAssertTrue(page.targets.contains { $0.target == .link("clip.mp4") && $0.rect == first.rect })
  }

  func testPostersAndLoadedFramesGiveTheRealSize() {
    let prepared = prepare("<video src=\"clip.mp4\" poster=\"still.png\"></video>")
    let page = prepared.layout(
      LayoutInput(width: 1200, imageSize: { $0 == "still.png" ? CGSize(width: 200, height: 100) : nil }))
    let box = page.images[0]
    XCTAssertEqual(box.content, .image(source: "still.png"))
    XCTAssertTrue(box.hasIntrinsicSize)
    XCTAssertEqual(
      box.rect.size,
      CGSize(width: prepared.typography.pixels(cssPoints: 200), height: prepared.typography.pixels(cssPoints: 100)))
  }

  func testEmbedsLinkToTheVideoPage() {
    let page = layout("<iframe src=\"https://www.youtube.com/embed/abc123\"></iframe>")
    XCTAssertEqual(page.images.first?.link, "https://www.youtube.com/watch?v=abc123")
    XCTAssertEqual(page.images.first?.content, .image(source: "https://img.youtube.com/vi/abc123/hqdefault.jpg"))
  }
}
