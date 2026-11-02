import CoreGraphics
import MDViewerCore
import XCTest

@testable import MDViewerDisplay

final class DisplayTransportTests: XCTestCase {
  private let output = RecordingOutput()
  private let source = SolidSource()
  private let stager = MemoryStager()
  private var events: [DisplayEvent] = []
  private var relayouts: [PaneSize] = []

  private func makeTransport(
    size: PaneSize = paneSize(columns: 10, rows: 5, cellWidth: 10, cellHeight: 20), fallback: FrameStager? = nil
  ) -> DisplayTransport {
    let transport = DisplayTransport(
      viewport: DisplayViewport(size: size, statusRows: 1, pageHeight: 1000), output: output, source: source,
      stager: stager, fallback: fallback, firstImageID: 100
    ) { [unowned self] size, old in
      relayouts.append(size)
      return DisplayViewport(size: size, statusRows: old.statusRows, pageHeight: old.pageHeight, offset: old.offset)
    }
    transport.onEvent = { [unowned self] in events.append($0) }
    return transport
  }

  private func acknowledge(_ transport: DisplayTransport, at now: UInt64) {
    guard let fence = transport.pacer.inFlight?.fence else { return XCTFail("nothing in flight") }
    transport.handle(GraphicsResponse(id: fence, message: "OK"), at: now)
  }

  func testFirstFullFrameIsByteExact() {
    let transport = makeTransport()
    transport.pump(at: 0)
    XCTAssertEqual(
      output.take(),
      [
        "\u{1b}[?2026h"
          + "\u{1b}_Ga=t,f=32,s=100,v=100,t=s,i=100,q=1;\(base64("/memory-1"))\u{1b}\\"
          + "\u{1b}[1;1H\u{1b}_Ga=p,i=100,p=1,c=10,r=5,C=1,q=1\u{1b}\\"
          + "\u{1b}[?2026l"
          + "\u{1b}_Ga=q,i=2147483648,s=1,v=1,f=32,t=d;AAAAAA==\u{1b}\\"
      ])
    XCTAssertEqual(stager.staged.first?.bytes, 100 * 100 * 4)
    XCTAssertEqual(source.frames.count, 1)
    acknowledge(transport, at: 3 * ms)
    XCTAssertEqual(output.take(), [])
    XCTAssertEqual(transport.ledger.displayed, 100)
    XCTAssertEqual(stager.outstanding, 0)
    XCTAssertTrue(events.contains { if case .acknowledged(_, let latency) = $0 { latency == 3 * ms } else { false } })
  }

  func testNextFullFrameDeletesThePreviousImageOnlyAfterItIsShown() {
    let transport = makeTransport()
    transport.pump(at: 0)
    acknowledge(transport, at: 1 * ms)
    output.writes = []
    transport.scroll(to: 400)
    transport.pump(at: 20 * ms)
    let frame = output.take()
    XCTAssertEqual(frame.count, 1)
    XCTAssertTrue(frame[0].contains("a=p,i=101,p=1"))
    XCTAssertFalse(frame[0].contains("a=d"))
    acknowledge(transport, at: 25 * ms)
    XCTAssertEqual(output.take(), ["\u{1b}_Ga=d,d=I,i=100,q=2\u{1b}\\"])
    XCTAssertEqual(transport.ledger.live, [101])
  }

  func testSmallScrollsShiftTheImageAndPatchTheExposedStrip() {
    let transport = makeTransport()
    transport.pump(at: 0)
    acknowledge(transport, at: 1 * ms)
    output.writes = []
    transport.scroll(rows: 1)
    transport.pump(at: 20 * ms)
    XCTAssertEqual(
      output.take(),
      [
        "\u{1b}[?2026h"
          + "\u{1b}_Ga=f,i=100,c=1,z=-1,s=1,v=1,f=32,t=d,X=1,q=1;AAAAAA==\u{1b}\\"
          + "\u{1b}_Ga=c,i=100,r=1,c=2,x=0,y=20,X=0,Y=20,w=100,h=60,C=1,q=1\u{1b}\\"
          + "\u{1b}_Ga=c,i=100,r=2,c=1,x=0,y=0,X=0,Y=20,w=100,h=60,C=1,q=1\u{1b}\\"
          + "\u{1b}_Ga=f,r=1,i=100,x=0,y=60,s=100,v=40,f=32,t=s,X=1,q=1;\(base64("/memory-2"))\u{1b}\\"
          + "\u{1b}[?2026l"
          + "\u{1b}_Ga=q,i=2147483649,s=1,v=1,f=32,t=d;AAAAAA==\u{1b}\\"
      ])
    XCTAssertEqual(source.patches, [PixelRect(x: 0, y: 60, width: 100, height: 40)])
    acknowledge(transport, at: 22 * ms)
    transport.scroll(rows: -1)
    transport.pump(at: 40 * ms)
    let up = output.take().joined()
    XCTAssertFalse(up.contains("c=1,z=-1"))
    XCTAssertTrue(up.contains("a=c,i=100,r=1,c=2,x=0,y=0,X=0,Y=0,w=100,h=60"))
    XCTAssertTrue(up.contains("a=c,i=100,r=2,c=1,x=0,y=20,X=0,Y=0,w=100,h=60"))
    XCTAssertEqual(
      Array(source.patches.suffix(2)),
      [PixelRect(x: 0, y: 0, width: 100, height: 20), PixelRect(x: 0, y: 80, width: 100, height: 20)])
  }

  func testFailedShiftFallsBackToFullFramesForGood() {
    let transport = makeTransport()
    transport.pump(at: 0)
    acknowledge(transport, at: 1 * ms)
    transport.scroll(rows: 1)
    transport.pump(at: 20 * ms)
    transport.handle(GraphicsResponse(id: 100, message: "ENOSPC: animation frame storage full"), at: 21 * ms)
    acknowledge(transport, at: 22 * ms)
    XCTAssertFalse(transport.shiftScrolling)
    transport.pump(at: 40 * ms)
    XCTAssertEqual(source.frames.count, 2)
    acknowledge(transport, at: 41 * ms)
    transport.scroll(rows: 1)
    transport.pump(at: 60 * ms)
    XCTAssertEqual(source.frames.count, 3)
  }

  func testScrollsBeforeTheFirstImageAreFullFrames() {
    let transport = makeTransport()
    transport.scroll(rows: 1)
    XCTAssertTrue(transport.damage.needsFullFrame)
  }

  func testSmallChangesArePatchedIntoTheDisplayedImage() {
    let transport = makeTransport()
    transport.pump(at: 0)
    acknowledge(transport, at: 1 * ms)
    output.writes = []
    transport.invalidateStatusBar()
    transport.invalidate(page: CGRect(x: 0, y: 10, width: 30, height: 5))
    transport.pump(at: 20 * ms)
    XCTAssertEqual(
      output.take(),
      [
        "\u{1b}[?2026h"
          + "\u{1b}_Ga=f,r=1,i=100,x=0,y=80,s=100,v=20,f=32,t=s,X=1,q=1;\(base64("/memory-2"))\u{1b}\\"
          + "\u{1b}_Ga=f,r=1,i=100,x=0,y=10,s=30,v=5,f=32,t=s,X=1,q=1;\(base64("/memory-3"))\u{1b}\\"
          + "\u{1b}[?2026l"
          + "\u{1b}_Ga=q,i=2147483649,s=1,v=1,f=32,t=d;AAAAAA==\u{1b}\\"
      ])
    XCTAssertEqual(
      source.patches, [PixelRect(x: 0, y: 80, width: 100, height: 20), PixelRect(x: 0, y: 10, width: 30, height: 5)])
    XCTAssertEqual(source.frames.count, 1)
  }

  func testLargePatchAreaFallsBackToAFullFrame() {
    let transport = makeTransport()
    transport.pump(at: 0)
    acknowledge(transport, at: 1 * ms)
    transport.invalidate(pane: PixelRect(x: 0, y: 0, width: 100, height: 41))
    transport.pump(at: 20 * ms)
    XCTAssertEqual(source.frames.count, 2)
    XCTAssertTrue(source.patches.isEmpty)
  }

  func testDamageOutsideTheViewportIsIgnored() {
    let transport = makeTransport()
    transport.pump(at: 0)
    acknowledge(transport, at: 1 * ms)
    output.writes = []
    transport.invalidate(page: CGRect(x: 0, y: 500, width: 30, height: 5))
    transport.pump(at: 20 * ms)
    XCTAssertEqual(output.writes, [])
    XCTAssertNil(transport.nextWake(after: 20 * ms))
  }

  func testPacingCoalescesChangesAndCapsInFlightFrames() {
    let transport = makeTransport()
    transport.pump(at: 0)
    transport.invalidateStatusBar()
    transport.pump(at: 1 * ms)
    XCTAssertEqual(source.patches.count, 0)
    XCTAssertEqual(transport.nextWake(after: 1 * ms), FramePacer.defaultFenceTimeout)
    acknowledge(transport, at: 2 * ms)
    transport.invalidate(page: CGRect(x: 0, y: 0, width: 10, height: 10))
    transport.pump(at: 5 * ms)
    XCTAssertEqual(source.patches.count, 0)
    XCTAssertEqual(transport.nextWake(after: 5 * ms), FramePacer.sixtyHertz)
    transport.pump(at: FramePacer.sixtyHertz)
    XCTAssertEqual(source.patches.count, 2)
  }

  func testFenceTimeoutPresumesTheFrameWasShown() {
    let transport = makeTransport()
    transport.pump(at: 0)
    transport.scroll(by: 40)
    transport.pump(at: FramePacer.defaultFenceTimeout)
    XCTAssertTrue(events.contains { if case .timedOut = $0 { true } else { false } })
    XCTAssertEqual(transport.ledger.displayed, 100)
    XCTAssertEqual(source.frames.count, 2)
    transport.handle(GraphicsResponse(id: FenceIDs.base, message: "OK"), at: FramePacer.defaultFenceTimeout + 1)
    XCTAssertNotNil(transport.pacer.inFlight)
  }

  func testResizeHoldsTheOldImageThenSwapsOnce() {
    let transport = makeTransport()
    transport.pump(at: 0)
    acknowledge(transport, at: 1 * ms)
    output.writes = []
    let wider = paneSize(columns: 12, rows: 5, cellWidth: 10, cellHeight: 20)
    let widest = paneSize(columns: 14, rows: 6, cellWidth: 10, cellHeight: 20)
    transport.observe(wider, at: 10 * ms)
    transport.invalidateStatusBar()
    transport.pump(at: 30 * ms)
    transport.observe(widest, at: 40 * ms)
    transport.pump(at: 100 * ms)
    XCTAssertEqual(output.writes, [])
    XCTAssertTrue(transport.isHolding)
    XCTAssertEqual(transport.nextWake(after: 100 * ms), 120 * ms)
    transport.pump(at: 120 * ms)
    XCTAssertEqual(relayouts, [widest])
    XCTAssertEqual(transport.viewport.size, widest)
    let swap = output.take()
    XCTAssertEqual(swap.count, 1)
    XCTAssertTrue(swap[0].contains("a=t,f=32,s=140,v=120,t=s,i=101"))
    XCTAssertTrue(swap[0].contains("a=p,i=101,p=1,c=14,r=6"))
    XCTAssertFalse(swap[0].contains("a=d"))
    acknowledge(transport, at: 130 * ms)
    XCTAssertEqual(output.take(), [Kitty.deleteImage(id: 100)])
    XCTAssertEqual(events.filter { if case .holding = $0 { true } else { false } }.count, 1)
    XCTAssertEqual(events.filter { if case .settled = $0 { true } else { false } }.count, 1)
  }

  func testAnImageIsAlwaysPlacedAcrossResizes() {
    let transport = makeTransport()
    var placed: Set<UInt32> = []
    var now: UInt64 = 0
    var blankWrites = 0
    func apply() {
      for write in output.take() {
        for match in write.matches(of: /a=p,i=(\d+)/) { placed.insert(UInt32(match.1)!) }
        for match in write.matches(of: /a=d,d=I,i=(\d+)/) { placed.remove(UInt32(match.1)!) }
        if placed.isEmpty { blankWrites += 1 }
      }
    }
    for step in 0..<200 {
      now += 7 * ms
      if step % 3 == 0 { transport.observe(paneSize(columns: 10 + step % 20, rows: 5 + step % 7), at: now) }
      if step % 5 == 0 { transport.scroll(by: 20) }
      if step % 4 == 0 { transport.invalidateStatusBar() }
      transport.pump(at: now)
      apply()
      if transport.pacer.inFlight != nil, step % 2 == 0 { acknowledge(transport, at: now) }
      apply()
    }
    XCTAssertEqual(blankWrites, 0)
    XCTAssertLessThanOrEqual(transport.ledger.live.count, 2)
  }

  func testTransmitErrorKeepsTheOldImageAndSwitchesToTheFallback() {
    let fallback = MemoryStager(name: "fallback")
    let transport = makeTransport(fallback: fallback)
    transport.pump(at: 0)
    acknowledge(transport, at: 1 * ms)
    transport.scroll(by: 400)
    transport.pump(at: 20 * ms)
    output.writes = []
    transport.handle(GraphicsResponse(id: 101, message: "EINVAL: unsupported medium"), at: 21 * ms)
    acknowledge(transport, at: 22 * ms)
    XCTAssertEqual(output.take(), [Kitty.deleteImage(id: 101)])
    XCTAssertEqual(transport.ledger.displayed, 100)
    XCTAssertEqual(transport.ledger.live, [100])
    XCTAssertTrue(stager.removed)
    transport.pump(at: 40 * ms)
    XCTAssertEqual(fallback.staged.count, 1)
    XCTAssertTrue(output.writes.joined().contains(base64("/fallback-1")))
  }

  func testPatchNotFoundForcesAFullFrameWithoutChangingMedium() {
    let fallback = MemoryStager(name: "fallback")
    let transport = makeTransport(fallback: fallback)
    transport.pump(at: 0)
    acknowledge(transport, at: 1 * ms)
    transport.invalidateStatusBar()
    transport.pump(at: 20 * ms)
    transport.handle(GraphicsResponse(id: 100, message: "ENOENT: image not found"), at: 21 * ms)
    acknowledge(transport, at: 22 * ms)
    transport.pump(at: 40 * ms)
    XCTAssertEqual(source.frames.count, 2)
    XCTAssertFalse(stager.removed)
    XCTAssertEqual(fallback.staged.count, 0)
  }

  func testStagingFailureUsesTheFallbackImmediately() {
    let fallback = MemoryStager(name: "fallback")
    stager.failNext = true
    let transport = makeTransport(fallback: fallback)
    transport.pump(at: 0)
    XCTAssertEqual(fallback.staged.count, 1)
    XCTAssertTrue(output.writes.joined().contains(base64("/fallback-1")))
  }

  func testStagingFailureWithoutFallbackRetriesLater() {
    stager.failNext = true
    let transport = makeTransport()
    transport.pump(at: 0)
    XCTAssertEqual(output.writes, [])
    XCTAssertTrue(events.contains { if case .failed = $0 { true } else { false } })
    XCTAssertTrue(transport.ledger.live.isEmpty)
    transport.pump(at: 20 * ms)
    XCTAssertEqual(output.writes.count, 1)
  }

  func testSizeBeforeTheFirstImageAppliesWithoutHolding() {
    let transport = makeTransport(size: PaneSize(columns: 10, rows: 5, pixelWidth: 0, pixelHeight: 0))
    transport.pump(at: 0)
    let reported = paneSize(columns: 12, rows: 6, cellWidth: 10, cellHeight: 20)
    transport.observe(reported, at: 1 * ms)
    XCTAssertFalse(transport.isHolding)
    XCTAssertEqual(relayouts, [reported])
    transport.observe(reported, at: 2 * ms)
    XCTAssertEqual(relayouts, [reported])
    transport.pump(at: 2 * ms)
    XCTAssertTrue(output.writes.joined().contains("a=t,f=32,s=120,v=120"))
  }

  func testScrollByRows() {
    let transport = makeTransport()
    XCTAssertTrue(transport.scroll(rows: 2))
    XCTAssertEqual(transport.viewport.offset, 40)
    XCTAssertFalse(transport.scroll(rows: 0))
  }

  func testUndrawableSizesSendNothing() {
    let transport = makeTransport(size: PaneSize(columns: 10, rows: 5, pixelWidth: 0, pixelHeight: 0))
    transport.pump(at: 0)
    XCTAssertEqual(output.writes, [])
    transport.observe(PaneSize(columns: 10, rows: 5, pixelWidth: 0, pixelHeight: 0), at: 0)
    XCTAssertFalse(transport.isHolding)
  }

  func testShutdownDeletesEveryImageAndStagedFrame() {
    let transport = makeTransport()
    transport.pump(at: 0)
    acknowledge(transport, at: 1 * ms)
    transport.scroll(by: 400)
    transport.pump(at: 20 * ms)
    output.writes = []
    transport.shutdown()
    XCTAssertEqual(output.take(), [Kitty.deleteImage(id: 100) + Kitty.deleteImage(id: 101)])
    XCTAssertTrue(stager.removed)
    XCTAssertTrue(transport.ledger.live.isEmpty)
    transport.shutdown()
    transport.pump(at: 100 * ms)
    XCTAssertEqual(output.writes, [])
  }

  func testLongSessionHasNoGrowth() {
    let transport = makeTransport()
    var now: UInt64 = 0
    for step in 0..<2_000 {
      now += 17 * ms
      if step % 2 == 0 { transport.scroll(by: step % 4 == 0 ? 20 : -20) } else { transport.invalidateStatusBar() }
      transport.pump(at: now)
      acknowledge(transport, at: now + 1 * ms)
    }
    XCTAssertEqual(stager.outstanding, 0)
    XCTAssertEqual(transport.ledger.live.count, 1)
    XCTAssertEqual(source.frames.count, 1)
    XCTAssertGreaterThan(source.patches.count, 2_000)
  }

  func testStaleStagedFramesAreReclaimedWhenFencesNeverReturn() {
    let transport = makeTransport()
    var now: UInt64 = 0
    for _ in 0..<40 {
      transport.scroll(by: 20)
      transport.pump(at: now)
      now += FramePacer.defaultFenceTimeout
    }
    transport.pump(at: now)
    XCTAssertLessThanOrEqual(
      stager.outstanding, Int(DisplayTransport.staleStagingNanoseconds / FramePacer.defaultFenceTimeout) + 1)
  }
}
