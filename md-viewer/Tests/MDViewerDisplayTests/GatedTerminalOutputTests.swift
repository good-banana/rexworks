import MDViewerCore
import XCTest

@testable import MDViewerDisplay

final class GatedTerminalOutputTests: XCTestCase {
  private let target = RecordingOutput()

  func testOpenGatePassesWritesThrough() {
    let gate = GatedTerminalOutput(target)
    gate.write("a")
    gate.write("b")
    XCTAssertEqual(target.writes, ["a", "b"])
  }

  func testClosedGateDropsEveryWrite() {
    let gate = GatedTerminalOutput(target)
    gate.closeGate()
    gate.write("a")
    gate.write("")
    XCTAssertFalse(gate.isOpen)
    XCTAssertEqual(target.writes, [])
  }

  func testGateCanBeStartedClosedAndReopened() {
    let gate = GatedTerminalOutput(target, isOpen: false)
    gate.write("dropped")
    gate.openGate()
    gate.write("kept")
    XCTAssertTrue(gate.isOpen)
    XCTAssertEqual(target.writes, ["kept"])
  }

  func testBypassWritesReachTheTargetWhileClosed() {
    let gate = GatedTerminalOutput(target, isOpen: false)
    gate.writeBypassingGate("direct")
    XCTAssertEqual(target.writes, ["direct"])
  }

  func testTransportWritesThroughTheGate() {
    let gate = GatedTerminalOutput(target)
    let transport = DisplayTransport(
      viewport: DisplayViewport(
        size: paneSize(columns: 10, rows: 5, cellWidth: 10, cellHeight: 20), statusRows: 1, pageHeight: 1000),
      output: gate, source: SolidSource(), stager: MemoryStager(), firstImageID: 100
    ) { size, old in
      DisplayViewport(size: size, statusRows: old.statusRows, pageHeight: old.pageHeight, offset: old.offset)
    }
    transport.pump(at: 0)
    XCTAssertFalse(target.take().isEmpty, "an open gate passes the transport's frame through")
    transport.handle(GraphicsResponse(id: transport.pacer.inFlight?.fence ?? 0, message: "OK"), at: 1)
    gate.closeGate()
    transport.invalidateAll()
    transport.pump(at: 100 * ms)
    XCTAssertEqual(target.writes, [])
  }

  private final class BlockingOutput: TerminalOutput, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recorded: [String] = []

    var writes: [String] { lock.withLock { recorded } }

    func write(_ text: String) {
      if text == "blocked" {
        entered.signal()
        release.wait()
      }
      lock.withLock { recorded.append(text) }
    }
  }

  func testClosingAndOpeningNeverWaitOnABlockedWrite() {
    let output = BlockingOutput()
    let gate = GatedTerminalOutput(output)
    let writer = DispatchGroup()
    DispatchQueue.global().async(group: writer) { gate.write("blocked") }
    XCTAssertEqual(output.entered.wait(timeout: .now() + 5), .success)

    let toggled = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      gate.closeGate()
      gate.openGate()
      gate.closeGate()
      toggled.signal()
    }
    let returned = toggled.wait(timeout: .now() + 2) == .success
    XCTAssertTrue(returned, "the gate waited for the blocked write")

    let bypass = DispatchGroup()
    DispatchQueue.global().async(group: bypass) { gate.writeBypassingGate("restore") }
    output.release.signal()
    XCTAssertEqual(writer.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(bypass.wait(timeout: .now() + 5), .success)
    if !returned { XCTAssertEqual(toggled.wait(timeout: .now() + 5), .success) }
    gate.write("late")
    XCTAssertEqual(output.writes, ["blocked", "restore"], "bypass writes queue behind the admitted write")
  }
}
