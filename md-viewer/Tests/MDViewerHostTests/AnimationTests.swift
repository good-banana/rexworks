import CoreGraphics
import Foundation
import ImageIO
import MDViewerCore
import MDViewerDisplay
import MDViewerInteraction
import XCTest

@testable import MDViewerHost

func animatedImageData(
  type: String = "com.compuserve.gif", width: Int = 40, height: Int = 20, delays: [Double], loopCount: Int? = 0
) -> Data {
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(data, type as CFString, delays.count, nil)!
  let isGIF = type == "com.compuserve.gif"
  if let loopCount {
    let key = isGIF ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
    let loop = isGIF ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
    CGImageDestinationSetProperties(destination, [key: [loop: loopCount]] as CFDictionary)
  }
  for (index, delay) in delays.enumerated() {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let shade = CGFloat(index) / CGFloat(max(delays.count - 1, 1))
    context.setFillColor(CGColor(srgbRed: shade, green: 0.2, blue: 1 - shade, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let frame: [CFString: Any] =
      isGIF
      ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
      : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
    CGImageDestinationAddImage(destination, context.makeImage()!, frame as CFDictionary)
  }
  CGImageDestinationFinalize(destination)
  return data as Data
}

final class AnimatedDecodeTests: XCTestCase {
  func testGIFFramesDelaysAndLoopCount() throws {
    let data = animatedImageData(delays: [0.01, 0.02, 0.05, 0], loopCount: 0)
    let image = try XCTUnwrap(ImageStore.decode(data, limits: ImageStore.Limits()))
    XCTAssertTrue(image.isAnimated)
    XCTAssertEqual(image.frames.count, 4)
    XCTAssertEqual(image.delays, [0.1, 0.02, 0.05, 0.1], "10 ms or less plays at 100 ms")
    XCTAssertEqual(image.loopCount, 0, "loops forever")
    XCTAssertEqual(image.frame(2).width, 40)
    let once = try XCTUnwrap(ImageStore.decode(animatedImageData(delays: [0.1, 0.1], loopCount: nil), limits: .init()))
    XCTAssertEqual(once.loopCount, 1, "a GIF without a loop extension plays once")
  }

  func testDelayFloor() {
    XCTAssertEqual(ImageStore.normalizedDelay(0.015), 0.02)
    XCTAssertEqual(ImageStore.normalizedDelay(0.01), 0.1)
    XCTAssertEqual(ImageStore.normalizedDelay(nil), 0.1)
    XCTAssertEqual(ImageStore.normalizedDelay(0.3), 0.3)
  }

  func testAPNGFrames() throws {
    let data = animatedImageData(type: "public.png", delays: [0.04, 0.08, 0.04], loopCount: 3)
    let image = try XCTUnwrap(ImageStore.decode(data, limits: ImageStore.Limits()))
    try XCTSkipUnless(image.isAnimated, "this ImageIO could not write an APNG")
    for (delay, expected) in zip(image.delays, [0.04, 0.08, 0.04]) { XCTAssertEqual(delay, expected, accuracy: 0.001) }
    XCTAssertEqual(image.loopCount, 3)
  }

  func testFramesAreDecodedAtTheDisplaySizeAndCappedInMemory() throws {
    let data = animatedImageData(width: 1200, height: 300, delays: [0.1, 0.1, 0.1])
    let scaled = try XCTUnwrap(ImageStore.decode(data, limits: ImageStore.Limits(), dimension: 600))
    XCTAssertTrue(scaled.frames.allSatisfy { $0.width == 600 })
    let capped = try XCTUnwrap(
      ImageStore.decode(data, limits: ImageStore.Limits(maximumAnimationBytes: 1200 * 300 * 4 * 2)))
    XCTAssertEqual(capped.frames.count, 1, "over the budget only the first frame is kept")
    XCTAssertFalse(capped.isAnimated)
  }
}

final class AnimationPlayerTests: XCTestCase {
  private let ms: UInt64 = 1_000_000

  func testFramesAdvanceLoopAndStop() {
    var player = AnimationPlayer()
    player.show(["a": .init(delays: [0.05, 0.1], loopCount: 2)], at: 0)
    XCTAssertEqual(player.nextDeadline, 50 * ms)
    XCTAssertEqual(player.advance(at: 49 * ms), [])
    XCTAssertEqual(player.advance(at: 50 * ms), ["a"])
    XCTAssertEqual(player.frame(for: "a"), 1)
    XCTAssertEqual(player.advance(at: 150 * ms), ["a"])
    XCTAssertEqual(player.frame(for: "a"), 0, "second loop")
    XCTAssertEqual(player.advance(at: 200 * ms), ["a"])
    XCTAssertEqual(player.advance(at: 300 * ms), [], "two loops played")
    XCTAssertEqual(player.frame(for: "a"), 1, "it rests on the last frame")
    XCTAssertNil(player.nextDeadline)
  }

  func testOffscreenClipsPauseAndResume() {
    var player = AnimationPlayer()
    let clip = AnimationPlayer.Clip(delays: [0.05, 0.05, 0.05], loopCount: 0)
    player.show(["a": clip], at: 0)
    _ = player.advance(at: 50 * ms)
    player.show([:], at: 60 * ms)
    XCTAssertNil(player.nextDeadline, "paused while off screen")
    XCTAssertEqual(player.advance(at: 500 * ms), [])
    XCTAssertEqual(player.frame(for: "a"), 1, "it keeps its frame")
    player.show(["a": clip], at: 600 * ms)
    XCTAssertEqual(player.nextDeadline, 650 * ms)
    XCTAssertTrue(player.playing.contains("a"))
  }
}

@MainActor
final class HostAnimationTests: XCTestCase {
  private func host(_ markdown: String, reduceMotion: Bool = false) throws -> (
    ViewerHost, RecordingOutput, TestDirectory
  ) {
    let directory = try TestDirectory()
    try animatedImageData(width: 200, height: 100, delays: [0.05, 0.05, 0.05]).write(
      to: directory.url.appendingPathComponent("spin.gif"))
    let file = try directory.write("main.md", markdown)
    let output = RecordingOutput()
    let services = HostServices(
      output: output, pasteboard: FakePasteboard(), stagers: (MemoryStager(), nil),
      environment: InteractionEnvironment(openURL: { _ in true }, copyOnSelect: { false }), watchesFiles: false,
      reduceMotion: { reduceMotion })
    let viewer = ViewerHost(
      size: testPaneSize, theme: ResolvedTheme(colors: TerminalColorSet(), source: .terminalQuery), services: services)
    viewer.start(file: file, windowSize: testPaneSize)
    spin(until: { viewer.interaction.layout?.images.first?.hasIntrinsicSize == true })
    return (viewer, output, directory)
  }

  private func acknowledge(_ host: ViewerHost, _ output: RecordingOutput) {
    for fence in fences(in: output.joined) { host.receive(Array("\u{1b}_Gi=\(fence);OK\u{1b}\\".utf8)) }
  }

  func testVisibleAnimationsRedrawOnlyTheirRect() throws {
    let (host, output, _) = try host("# GIF\n\n![spin](spin.gif)\n\nText.")
    acknowledge(host, output)
    spin(0.1)
    acknowledge(host, output)
    let start = output.writes.count
    for _ in 0..<12 {
      spin(0.05)
      acknowledge(host, output)
    }
    XCTAssertGreaterThanOrEqual(host.animationFrames.index(for: "spin.gif") + 1, 1)
    let writes = output.writes[start...].joined()
    XCTAssertTrue(writes.contains("a=f,"), "frames go out as patches")
    XCTAssertFalse(writes.contains("a=p,"), "no full frame is placed")
    let box = try XCTUnwrap(host.interaction.layout?.images.first?.rect)
    let patch = try XCTUnwrap(
      writes.range(of: #"a=f,r=1,i=\d+,x=(\d+),y=(\d+),s=(\d+),v=(\d+)"#, options: .regularExpression))
    let fields = writes[patch].split(separator: ",").compactMap { $0.split(separator: "=").last.flatMap { Int($0) } }
    XCTAssertLessThanOrEqual(fields[4], Int(box.width.rounded(.up)) + 2, "patch width is the image's")
    XCTAssertLessThanOrEqual(fields[5], Int(box.height.rounded(.up)) + 2, "patch height is the image's")
    host.shutdown()
  }

  func testOffscreenHelpAndReduceMotionPause() throws {
    let below = String(repeating: "Paragraph of filler text.\n\n", count: 120)
    let (offscreen, _, _) = try host("# GIF\n\n" + below + "![spin](spin.gif)")
    XCTAssertTrue(offscreen.player.playing.isEmpty, "an image below the view does not animate")
    offscreen.receive(Array("G".utf8))
    XCTAssertEqual(offscreen.player.playing, ["spin.gif"], "scrolled into view, it plays")
    XCTAssertNotNil(offscreen.animationTimerDeadline)
    offscreen.receive(Array("?".utf8))
    XCTAssertTrue(offscreen.player.playing.isEmpty, "help pauses it")
    XCTAssertNil(offscreen.animationTimerDeadline, "the timer goes idle instead of waking once more")
    offscreen.shutdown()

    let (reduced, _, _) = try host("![spin](spin.gif)", reduceMotion: true)
    spin(0.3)
    XCTAssertTrue(reduced.player.playing.isEmpty)
    XCTAssertEqual(reduced.animationFrames.index(for: "spin.gif"), 0, "Reduce Motion shows the first frame")
    reduced.shutdown()
  }
}
