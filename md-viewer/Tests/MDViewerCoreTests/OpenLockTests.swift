import XCTest

@testable import MDViewerCore

final class OpenLockTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var all: [String] { lock.withLock { recorded } }
    func record(_ event: String) { lock.withLock { recorded.append(event) } }
  }

  func testConcurrentOpensPlanOneAtATime() throws {
    let url = directory.appendingPathComponent("support/open.lock")
    let events = Events()
    let group = DispatchGroup()
    for name in ["first", "second", "third"] {
      DispatchQueue.global().async(group: group) {
        let lock = OpenLock.acquire(url)
        events.record("probe \(name)")
        Thread.sleep(forTimeInterval: 0.15)
        events.record("split \(name)")
        lock?.release()
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    let recorded = events.all
    XCTAssertEqual(recorded.count, 6)
    for pair in stride(from: 0, to: recorded.count, by: 2) {
      let name = try XCTUnwrap(recorded[pair].split(separator: " ").last)
      XCTAssertEqual(recorded[pair], "probe \(name)")
      XCTAssertEqual(recorded[pair + 1], "split \(name)", "\(recorded)")
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testAHeldLockIsGivenUpAfterTheTimeout() throws {
    let url = directory.appendingPathComponent("open.lock")
    let holder = try XCTUnwrap(OpenLock.acquire(url))
    let started = Date()
    XCTAssertNil(OpenLock.acquire(url, timeout: 0.2))
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.2)
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    holder.release()
    XCTAssertNotNil(OpenLock.acquire(url, timeout: 0))
  }

  func testAReleasedOrDroppedLockCanBeTakenAgain() throws {
    let url = directory.appendingPathComponent("open.lock")
    var held = OpenLock.acquire(url)
    XCTAssertNotNil(held)
    held = nil
    XCTAssertNotNil(OpenLock.acquire(url, timeout: 0))
  }

  func testASymlinkedLockFileIsRefused() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent("elsewhere")
    let url = directory.appendingPathComponent("open.lock")
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    XCTAssertNil(OpenLock.acquire(url, timeout: 0))
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }

  func testAnEditIsDeliveredBeforeAConcurrentOpenCanRetargetThePreview() throws {
    let url = directory.appendingPathComponent("support/open.lock")
    let events = Events()
    let concurrent = DispatchGroup()
    let delivery = openAndDeliverEdit(
      lock: url,
      open: {
        events.record("open")
        return "block:preview"
      },
      deliver: { block in
        DispatchQueue.global().async(group: concurrent) {
          let lock = OpenLock.acquire(url)
          events.record("concurrent open")
          lock?.release()
        }
        Thread.sleep(forTimeInterval: 0.2)
        events.record("edit \(block)")
        return true
      })
    XCTAssertEqual(concurrent.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(delivery, .delivered)
    XCTAssertEqual(events.all, ["open", "edit block:preview", "concurrent open"])
  }

  func testAnEditWithoutAPreviewOrAnAnswerReportsWhy() {
    let url = directory.appendingPathComponent("support/open.lock")
    var delivered: [String] = []
    let missing = openAndDeliverEdit(
      lock: url, open: { nil },
      deliver: {
        delivered.append($0)
        return true
      })
    XCTAssertEqual(missing, .noPreview)
    XCTAssertEqual(delivered, [])
    XCTAssertEqual(openAndDeliverEdit(lock: url, open: { "block:p" }, deliver: { _ in false }), .unreachable)
    XCTAssertNotNil(OpenLock.acquire(url, timeout: 0), "the lock is released afterwards")
  }
}
