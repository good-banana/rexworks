import CoreGraphics
import Darwin
import Foundation
import MDViewerCore
import XCTest

@testable import MDViewerHost

final class SVGRenderProcessTests: XCTestCase {
  private let badge = Data(
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="106" height="20"><rect width="57" height="20" fill="#555"/>\
    <rect x="57" width="49" height="20" fill="#007ec6"/></svg>
    """.utf8)

  private let canvas = Data(
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024"><rect width="1024" height="1024" fill="red"/>\
    </svg>
    """.utf8)

  private var slow: Data {
    Data(
      ("<svg xmlns='http://www.w3.org/2000/svg' width='1024' height='1024'>"
        + "<filter id='b'><feGaussianBlur stdDeviation='200'/></filter>"
        + String(repeating: "<rect width='1024' height='1024' fill='red' filter='url(#b)'/>", count: 1_000)
        + "</svg>").utf8)
  }

  func testTheChildRendersWhatTheViewerWouldRender() throws {
    let process = SVGRenderProcess(executable: mdViewerExecutable)
    let child = try XCTUnwrap(process.render(badge, limits: ImageStore.Limits(), dimension: nil))
    let local = try XCTUnwrap(ImageStore.decodeSVG(badge, limits: ImageStore.Limits(), dimension: nil))
    XCTAssertTrue(child.isVector)
    XCTAssertEqual(child.size, CGSize(width: 106, height: 20))
    XCTAssertEqual(child.image.width, 424)
    XCTAssertEqual(child.image.height, 80)
    XCTAssertEqual(pixels(child.image), pixels(local.image))
  }

  func testTheChildHonorsTheDisplayWidthAndPixelLimits() throws {
    let process = SVGRenderProcess(executable: mdViewerExecutable)
    let fitted = try XCTUnwrap(process.render(canvas, limits: ImageStore.Limits(), dimension: 512))
    XCTAssertEqual(fitted.image.width, 512)
    let bounded = try XCTUnwrap(
      process.render(canvas, limits: ImageStore.Limits(maximumPixels: 100 * 100), dimension: nil))
    XCTAssertLessThanOrEqual(bounded.image.width * bounded.image.height, 100 * 100)
  }

  func testAChildThatRunsTooLongIsKilledAndReaped() {
    let process = SVGRenderProcess(executable: mdViewerExecutable, timeout: 0.3)
    let resources = Resources()
    let started = Date()
    XCTAssertNil(process.render(slow, limits: ImageStore.Limits(), dimension: nil))
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3, "the child ran until the deadline")
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    resources.assertReleased()
  }

  func testAChildThatUsesTooMuchMemoryIsKilledAndReaped() throws {
    let limited = SVGRenderProcess(executable: mdViewerExecutable, timeout: 30, memoryLimit: 32 << 20)
    let resources = Resources()
    let started = Date()
    XCTAssertNil(limited.render(canvas, limits: ImageStore.Limits(), dimension: nil))
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    resources.assertReleased()
    let unlimited = SVGRenderProcess(executable: mdViewerExecutable, timeout: 30)
    XCTAssertEqual(unlimited.render(canvas, limits: ImageStore.Limits(), dimension: nil)?.image.width, 4096)
  }

  func testOutputPastTheCapIsNotRead() {
    let process = SVGRenderProcess(executable: URL(fileURLWithPath: "/usr/bin/yes"), timeout: 30)
    let resources = Resources()
    let started = Date()
    XCTAssertNil(process.run(URL(fileURLWithPath: "/usr/bin/yes"), input: Data(), outputLimit: 1 << 16))
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    resources.assertReleased()
  }

  func testFailedOrMissingChildrenFailCleanly() {
    let resources = Resources()
    let missing = SVGRenderProcess(executable: URL(fileURLWithPath: "/nonexistent/md-viewer"))
    XCTAssertNil(missing.render(badge, limits: ImageStore.Limits(), dimension: nil))
    XCTAssertNil(SVGRenderProcess(executable: nil).render(badge, limits: ImageStore.Limits(), dimension: nil))
    let failing = SVGRenderProcess(executable: URL(fileURLWithPath: "/usr/bin/false"))
    XCTAssertNil(failing.render(badge, limits: ImageStore.Limits(), dimension: nil))
    let echoing = SVGRenderProcess(executable: URL(fileURLWithPath: "/bin/cat"))
    XCTAssertNil(echoing.render(badge, limits: ImageStore.Limits(), dimension: nil), "garbage output is rejected")
    resources.assertReleased()
  }

  func testAnUpgradedAwayExecutableFallsBackToTheLaunchPath() throws {
    let directory = try TestDirectory()
    let link = directory.url.appendingPathComponent("md-viewer")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: mdViewerExecutable)
    let removed = directory.url.appendingPathComponent("Cellar/old/md-viewer")
    let resources = Resources()
    let process = SVGRenderProcess(executable: removed, launchPath: link)
    let child = try XCTUnwrap(process.render(badge, limits: ImageStore.Limits(), dimension: nil))
    XCTAssertEqual(child.size, CGSize(width: 106, height: 20))
    resources.assertReleased()
  }

  func testTheFallbackIsOnlyAnExecutableFileAndOnlyForAMissingExecutable() throws {
    let directory = try TestDirectory()
    let removed = directory.url.appendingPathComponent("missing")
    let plain = try directory.write("plain", "#!/bin/sh\n")
    let link = directory.url.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: mdViewerExecutable)
    XCTAssertEqual(
      SVGRenderProcess.replacement(for: removed, launchPath: link), mdViewerExecutable.resolvingSymlinksInPath())
    XCTAssertNil(SVGRenderProcess.replacement(for: removed, launchPath: nil))
    XCTAssertNil(SVGRenderProcess.replacement(for: removed, launchPath: plain), "not executable")
    XCTAssertNil(SVGRenderProcess.replacement(for: removed, launchPath: directory.url), "a directory")
    XCTAssertNil(SVGRenderProcess.replacement(for: removed, launchPath: removed))
    XCTAssertNil(
      SVGRenderProcess.replacement(for: mdViewerExecutable.resolvingSymlinksInPath(), launchPath: link),
      "the same missing file is not retried")
    let resources = Resources()
    let notExecutable = SVGRenderProcess(executable: plain, launchPath: link)
    XCTAssertNil(notExecutable.render(badge, limits: ImageStore.Limits(), dimension: nil), "only ENOENT retries")
    resources.assertReleased()
  }

  func testAChildSpeakingAnotherProtocolVersionRefuses() throws {
    XCTAssertNotEqual(SVGRenderProcess.serve(arguments: []), 0)
    XCTAssertNotEqual(SVGRenderProcess.serve(arguments: ["0"]), 0)
    let child = Process()
    child.executableURL = mdViewerExecutable
    child.arguments = [SVGRenderProcess.command, "0"]
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.nullDevice
    try child.run()
    child.waitUntilExit()
    XCTAssertNotEqual(child.terminationStatus, 0)
  }

  func testMalformedResponsesAreRejected() {
    var trailer = Data()
    for value in [2, 2, Int(bitPattern: UInt(Double(2).bitPattern)), Int(bitPattern: UInt(Double(2).bitPattern))] {
      withUnsafeBytes(of: Int64(value).littleEndian) { trailer.append(contentsOf: $0) }
    }
    let limits = ImageStore.Limits()
    XCTAssertNotNil(SVGRenderProcess.response(Data(count: 16) + trailer, limits: limits))
    XCTAssertNil(SVGRenderProcess.response(Data(count: 15) + trailer, limits: limits))
    XCTAssertNil(SVGRenderProcess.response(Data(count: 16) + trailer, limits: ImageStore.Limits(maximumPixels: 3)))
    XCTAssertNil(SVGRenderProcess.response(trailer.prefix(31), limits: limits))
    XCTAssertNil(
      SVGRenderProcess.response(Data(count: 16) + trailer, limits: ImageStore.Limits(maximumSourcePixels: 3)),
      "the reported size is bounded like an in-process render")
  }

  func testTheChildCommandIsHiddenFromHelp() {
    XCTAssertFalse(commandUsage.contains(SVGRenderProcess.command))
  }

  private func pixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
      data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
  }
}

private struct Resources {
  let descriptors = Self.openDescriptors()
  let children = Self.children()

  func assertReleased(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(Self.openDescriptors(), descriptors, "no descriptor leaks", file: file, line: line)
    XCTAssertTrue(Set(Self.children()).isSubset(of: children), "no child is left behind", file: file, line: line)
  }

  static func openDescriptors() -> Set<Int32> {
    Set((0..<Int32(4096)).filter { fcntl($0, F_GETFD) != -1 })
  }

  static func children() -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 1024)
    let count = pids.withUnsafeMutableBytes { proc_listchildpids(getpid(), $0.baseAddress, Int32($0.count)) }
    return Array(pids.prefix(max(Int(count), 0)))
  }
}
