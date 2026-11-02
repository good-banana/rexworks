import MDViewerDocument
import XCTest

final class VideoTests: XCTestCase {
  func testVideoElementsBecomeVideoImages() {
    XCTAssertEqual(
      paragraphShape("x <video src=\"clip.mp4\" poster=\"still.png\" width=\"320\" controls>Fallback</video>"),
      "\"x \" img(still.png width=320 video=clip.mp4: \"Video\")")
    XCTAssertEqual(
      paragraphShape("x <video controls><source src=\"\"><source src=\"clip.webm\" type=\"video/webm\"></video> y"),
      "\"x \" img( video=clip.webm: \"Video\") \" y\"")
    XCTAssertEqual(paragraphShape("x <video>No source</video> y"), "\"x  y\"")
    XCTAssertEqual(paragraphShape("x <video src=\"javascript:alert(1)\"></video>"), "\"x \"")
    XCTAssertEqual(
      paragraphShape("x <video src=\"a.mp4\" poster=\"javascript:alert(1)\"></video>"),
      "\"x \" img( video=a.mp4: \"Video\")")
  }

  func testVideoOnItsOwnLineAndInsideAnHTMLBlock() {
    XCTAssertEqual(paragraphShape("<video src=\"demo.mov\"></video>\n\nAfter."), "img( video=demo.mov: \"Video\")")
    let division = Document.parse("<div align=\"center\">\n<video src=\"demo.mov\"></video>\n</div>").blocks.first?
      .division
    XCTAssertTrue(division.map { shape($0.blocks).contains("video=demo.mov") } ?? false)
  }

  func testYouTubeAndVimeoEmbedsBecomeVideoLinks() {
    XCTAssertEqual(
      paragraphShape("x <iframe src=\"https://www.youtube.com/embed/dQw4w9WgXcQ\" allowfullscreen>junk</iframe> y"),
      "\"x \" img(https://img.youtube.com/vi/dQw4w9WgXcQ/hqdefault.jpg video=https://www.youtube.com/watch?v=dQw4w9WgXcQ: \"Video\") \" y\""
    )
    XCTAssertEqual(
      paragraphShape("x <iframe src=\"//player.vimeo.com/video/76979871\"></iframe>"),
      "\"x \" img( video=https://vimeo.com/76979871: \"Video\")")
    XCTAssertEqual(paragraphShape("x <iframe src=\"https://evil.example/embed\">text</iframe> y"), "\"x  y\"")
  }

  func testEmbedRules() {
    XCTAssertEqual(VideoEmbed(source: "https://youtu.be/abc_DEF-1")?.href, "https://www.youtube.com/watch?v=abc_DEF-1")
    XCTAssertEqual(
      VideoEmbed(source: "https://www.youtube-nocookie.com/embed/xyz")?.poster,
      "https://img.youtube.com/vi/xyz/hqdefault.jpg")
    XCTAssertNil(VideoEmbed(source: "https://vimeo.com/"))
    XCTAssertNil(VideoEmbed(source: "javascript://youtube.com/x"))
    XCTAssertNil(VideoEmbed(source: "https://youtube.com/embed/a%22b"))
  }
}
