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
    gate.closeGate()
    transport.pump(at: 0)
    XCTAssertEqual(target.writes, [])
  }
}
