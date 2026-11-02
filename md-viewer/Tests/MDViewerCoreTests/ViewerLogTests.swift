import Foundation
import XCTest

@testable import MDViewerCore

final class ViewerLogTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testAppendsTimestampedLinesWithPrivatePermissions() throws {
    let url = directory.appendingPathComponent("logs/viewer.log")
    let log = ViewerLog(url: url, now: { Date(timeIntervalSince1970: 0) })
    log.write("first")
    log.write("second")
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.count, 2)
    XCTAssertTrue(lines[0].hasPrefix("1970-01-01T00:00:00Z [\(getpid())] first"))
    XCTAssertTrue(lines[1].hasSuffix("second"))
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    XCTAssertEqual(permissions, 0o600)
  }

  func testStartsOverWhenTheLogWouldGrowPastTheLimit() throws {
    let url = directory.appendingPathComponent("viewer.log")
    let log = ViewerLog(url: url)
    let line = String(repeating: "x", count: 1024)
    for _ in 0..<(ViewerLog.maximumBytes / 1024 + 5) { log.write(line) }
    let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    XCTAssertLessThanOrEqual(size, ViewerLog.maximumBytes)
    XCTAssertGreaterThan(size, 0)
  }
}
