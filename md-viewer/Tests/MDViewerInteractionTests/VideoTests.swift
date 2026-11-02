import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout
import XCTest

@testable import MDViewerInteraction

final class VideoInteractionTests: XCTestCase {
  private let markdown = """
    Intro text.

    <video src="clip.mp4" width="200"></video>

    <iframe src="https://www.youtube.com/embed/abc123" width="200"></iframe>
    """

  private func box(_ h: Harness, _ index: Int) -> CGPoint {
    let rect = h.layout.images[index].rect
    return CGPoint(x: rect.midX, y: rect.midY)
  }

  func testClickingAVideoOpensItThroughTheLinkRouting() {
    var h = Harness(markdown, height: 1400, files: ["/docs/clip.mp4": ""])
    h.click(box(h, 0))
    XCTAssertEqual(h.system.opened, [URL(fileURLWithPath: "/docs/clip.mp4")])
    h.click(box(h, 1))
    XCTAssertEqual(h.system.opened.last, URL(string: "https://www.youtube.com/watch?v=abc123"))
  }

  func testUnsafeLocalMediaIsRefused() {
    var h = Harness(markdown, height: 1400, files: ["/docs/clip.mp4": ""])
    h.system.safeLocal = false
    h.click(box(h, 0))
    XCTAssertTrue(h.system.opened.isEmpty)
    XCTAssertEqual(h.model.status.message?.text, "Not opening clip.mp4")
  }

  func testTabFocusesVideosAndEnterOpensThem() {
    var h = Harness(markdown, height: 1400, files: ["/docs/clip.mp4": ""])
    h.key(.tab)
    XCTAssertEqual(h.model.focus, .video(0, href: "clip.mp4"))
    XCTAssertEqual(h.model.overlay.focus, .target(.link("clip.mp4")))
    h.key(.enter)
    XCTAssertEqual(h.system.opened, [URL(fileURLWithPath: "/docs/clip.mp4")])
    h.key(.tab)
    XCTAssertEqual(h.model.focus, .video(1, href: "https://www.youtube.com/watch?v=abc123"))
    h.key(.enter)
    XCTAssertEqual(h.system.opened.last, URL(string: "https://www.youtube.com/watch?v=abc123"))
  }

  func testClickingAVideoGivesItPointerFocus() {
    var h = Harness(markdown, height: 1400, files: ["/docs/clip.mp4": ""])
    h.click(box(h, 1))
    XCTAssertEqual(h.model.focus, .video(1, href: "https://www.youtube.com/watch?v=abc123"))
    XCTAssertNil(h.model.overlay.focus, "pointer focus draws no ring")
  }
}
