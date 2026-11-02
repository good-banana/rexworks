import CoreGraphics
import Foundation
import MDViewerCore
import XCTest

@testable import MDViewerMermaid

@MainActor
final class MermaidPolicyTests: XCTestCase {
  private let theme = MermaidTheme(palette: .fallback(dark: true))

  private func request(_ code: String, width: CGFloat = 400, scale: CGFloat = 1) -> MermaidRequest {
    MermaidRequest(code: code, theme: theme, width: width, scale: scale)
  }

  func testCallbacksArriveOnCallerQueueWithSizeFirst() async throws {
    let renderer = MermaidRenderer()
    let queue = DispatchQueue(label: "mermaid.test.caller", attributes: .concurrent)
    let recording = RenderRecording()
    let diagram = await withCheckedContinuation { continuation in
      renderer.render(
        request("flowchart TD\n  A --> B"), queue: queue,
        sizeReady: {
          dispatchPrecondition(condition: .onQueue(queue))
          recording.size($0)
        },
        completion: { diagram in
          dispatchPrecondition(condition: .onQueue(queue))
          recording.completed()
          continuation.resume(returning: diagram)
        })
    }
    XCTAssertNil(diagram.failure)
    XCTAssertEqual(recording.recordedEvents, ["size", "image"])
  }

  func testBudgetCappedDiagramIsCached() async throws {
    let budget = 20_000
    let renderer = MermaidRenderer(configuration: .init(cacheByteLimit: budget * 4, maximumPixels: budget))
    let capped = request(try sampleFlowchart(), width: 760, scale: 2)
    let diagram = await render(renderer, capped)
    XCTAssertNil(diagram.failure)
    XCTAssertLessThanOrEqual(diagram.image.width * diagram.image.height, budget)
    XCTAssertLessThanOrEqual(diagram.image.bytesPerRow * diagram.image.height, budget * 4)
    XCTAssertGreaterThan(diagram.size.width, 300)
    XCTAssertTrue(renderer.isCachedInMainStore(capped))
  }

  func testDefaultBudgetFitsTheCacheFourTimes() {
    let configuration = MermaidRenderer.Configuration()
    XCTAssertGreaterThanOrEqual(configuration.cacheByteLimit, configuration.maximumPixels * 4 * 4)
    for (width, height) in [(4000.0, 4000.0), (1234.5, 987.3), (8191.7, 3.3), (333.3, 2999.9)] {
      let size = CGSize(width: width, height: height)
      for scale in [1.0, 2.0, 3.0] {
        let raster = MermaidRaster.rasterScale(for: size, scale: scale, maximumPixels: configuration.maximumPixels)
        let pixels = MermaidRaster.pixelSize(size, scale: raster)
        XCTAssertLessThanOrEqual(pixels.width * pixels.height, configuration.maximumPixels, "\(size) @\(scale)")
      }
    }
  }

  func testTallDiagramsAreCappedToTheAspectRatio() async throws {
    XCTAssertEqual(
      MermaidRaster.fit(CGSize(width: 100, height: 1000), within: 200, maximumAspectRatio: 4),
      CGSize(width: 80, height: 800))
    XCTAssertEqual(
      MermaidRaster.fit(CGSize(width: 1000, height: 200), within: 500, maximumAspectRatio: 4),
      CGSize(width: 500, height: 100))
    let renderer = MermaidRenderer(configuration: .init(maximumAspectRatio: 1))
    let chain = "flowchart TD\n" + (0..<12).map { "  N\($0) --> N\($0 + 1)" }.joined(separator: "\n")
    let diagram = await render(renderer, request(chain, width: 400, scale: 1))
    XCTAssertNil(diagram.failure)
    XCTAssertLessThanOrEqual(diagram.size.height, 400.5)
    XCTAssertEqual(diagram.image.height, Int(diagram.size.height.rounded(.down)))
  }

  func testErrorBoxFollowsTheRequestWidth() {
    XCTAssertEqual(MermaidErrorImage.make(.timedOut, theme: theme, width: 60, scale: 2).size.width, 60)
    XCTAssertEqual(MermaidErrorImage.make(.timedOut, theme: theme, width: 9000, scale: 1).size.width, 4096)
  }

  func testTimeoutRetriesOnceWithALongerDeadline() async throws {
    let renderer = MermaidRenderer(
      configuration: .init(diagramTimeout: 0.001, retryTimeout: 15, timeoutRetryDelay: 0.5))
    let slow = request(try sampleFlowchart(), width: 500)
    let first = await render(renderer, slow)
    XCTAssertEqual(first.failure, .timedOut)
    XCTAssertEqual(first.size.width, 496)
    XCTAssertFalse(renderer.engine.isRunning)
    XCTAssertEqual(renderer.cached(slow)?.failure, .timedOut, "providers show the error box")
    XCTAssertFalse(renderer.isCachedInMainStore(slow))

    let otherWidth = await render(renderer, request(slow.code, width: 300, scale: 2))
    XCTAssertEqual(otherWidth.failure, .timedOut, "the record covers every width and scale")
    XCTAssertEqual(renderer.engine.startCount, 1)

    try await pause(0.6)
    let retried = await render(renderer, slow)
    XCTAssertNil(retried.failure)
    XCTAssertEqual(renderer.engine.startCount, 2)
    XCTAssertTrue(renderer.isCachedInMainStore(slow))
  }

  func testSecondTimeoutIsServedFromTheFailureStore() async throws {
    let renderer = MermaidRenderer(
      configuration: .init(diagramTimeout: 0.001, retryTimeout: 0.001, timeoutRetryDelay: 0.3))
    let slow = request(try sampleFlowchart())
    let first = await render(renderer, slow)
    XCTAssertEqual(first.failure, .timedOut)
    try await pause(0.4)
    let retried = await render(renderer, slow)
    XCTAssertEqual(retried.failure, .timedOut)
    XCTAssertEqual(renderer.engine.startCount, 2)
    try await pause(0.4)
    let later = await render(renderer, request(slow.code, width: 640))
    XCTAssertEqual(later.failure, .timedOut)
    XCTAssertEqual(renderer.engine.startCount, 2, "no further attempts")
    XCTAssertEqual(renderer.cached(slow)?.failure, .timedOut)
  }

  func testUnavailableResultsBackOffAndExpire() async throws {
    let renderer = MermaidRenderer(configuration: .init(failureBackoff: 0.3), pageURL: nil)
    let missing = request("flowchart LR\n  A --> B")
    let diagram = await render(renderer, missing)
    guard case .unavailable = diagram.failure else { return XCTFail("\(String(describing: diagram.failure))") }
    XCTAssertEqual(renderer.cached(missing)?.failure, diagram.failure, "providers show the error box")
    XCTAssertNotNil(renderer.imageProvider(theme: theme, width: 400, scale: 1)(missing.code))
    XCTAssertFalse(renderer.isCachedInMainStore(missing))
    try await pause(0.4)
    XCTAssertNil(renderer.cached(missing), "retried after the backoff")
  }

  func testLoadTimeoutFailsQueuedJobsAndBacksOff() async throws {
    let renderer = MermaidRenderer(configuration: .init(loadTimeout: 0.001, failureBackoff: 0.5))
    let first = request("flowchart LR\n  A --> B")
    let second = request("flowchart LR\n  C --> D")
    let third = request("flowchart LR\n  E --> F")
    async let a = render(renderer, first)
    async let b = render(renderer, second)
    async let c = render(renderer, third)
    let results = await [a, b, c]
    for result in results {
      guard case .unavailable(let reason) = result.failure else {
        return XCTFail("\(String(describing: result.failure))")
      }
      XCTAssertFalse(reason.isEmpty)
    }
    XCTAssertEqual(renderer.engine.startCount, 1, "queued jobs fail without their own load")

    let during = await render(renderer, request("flowchart LR\n  G --> H"))
    guard case .unavailable = during.failure else { return XCTFail("\(String(describing: during.failure))") }
    XCTAssertEqual(renderer.engine.startCount, 1, "no restart during the backoff")

    try await pause(0.6)
    _ = await render(renderer, request("flowchart LR\n  I --> J"))
    XCTAssertEqual(renderer.engine.startCount, 2)
  }

  func testDroppedRequestsCompleteAsCancelledAndCanBeRequestedAgain() async throws {
    let renderer = MermaidRenderer()
    let requests = ["A", "B", "C"].map { request("flowchart LR\n  \($0)1 --> \($0)2") }
    let results = DiagramResults()
    let recording = RenderRecording()
    let finished = expectation(description: "all callbacks")
    finished.expectedFulfillmentCount = 3
    for (index, current) in requests.enumerated() {
      renderer.render(
        current, sizeReady: { size in if index == 1 { recording.size(size) } },
        completion: { diagram in
          if index == 1 { recording.completed() }
          results.set(index, diagram)
          finished.fulfill()
        })
    }
    renderer.setCurrentDiagrams([requests[0]])
    await fulfillment(of: [finished], timeout: 20)

    XCTAssertNil(results.get(0)?.failure)
    XCTAssertEqual(results.get(1)?.failure, .cancelled)
    XCTAssertEqual(results.get(2)?.failure, .cancelled)
    XCTAssertEqual(recording.recordedEvents, ["image"], "no size for a cancelled request")
    XCTAssertEqual(renderer.engine.startedJobs, [requests[0].code])
    XCTAssertNil(renderer.cached(requests[1]), "cancellation is never cached")
    XCTAssertNil(renderer.sizeProvider(theme: theme, width: 400, scale: 1)(requests[1].code))

    let again = await render(renderer, requests[1])
    XCTAssertNil(again.failure, "a dropped key renders when requested again")
  }

  func testCurrentDiagramsRunInDocumentOrder() async throws {
    let renderer = MermaidRenderer()
    let codes = (1...5).map { "flowchart LR\n  N\($0) --> M\($0)" }
    let requests = codes.map { request($0) }
    renderer.setCurrentDiagrams(requests)
    let finished = expectation(description: "all diagrams")
    finished.expectedFulfillmentCount = codes.count
    for current in requests.reversed() {
      renderer.render(current) { diagram in
        XCTAssertNil(diagram.failure)
        finished.fulfill()
      }
    }
    await fulfillment(of: [finished], timeout: 20)
    XCTAssertEqual(renderer.engine.startedJobs, codes)
  }

  func testConcurrentRequestsAndDropsNeverLoseACallback() async throws {
    let renderer = MermaidRenderer()
    let requests = (0..<5).map { request("flowchart LR\n  R\($0) --> S\($0)") }
    let total = 40
    let finished = expectation(description: "every request completes")
    finished.expectedFulfillmentCount = total
    let outcomes = RenderRecording()
    DispatchQueue.global().async {
      DispatchQueue.concurrentPerform(iterations: total) { index in
        if index % 4 == 0 {
          renderer.setCurrentDiagrams(Array(requests.shuffled().prefix(2)))
        }
        renderer.render(requests[index % requests.count], queue: .global()) { diagram in
          XCTAssertTrue(
            diagram.failure == nil || diagram.failure == .cancelled, "\(String(describing: diagram.failure))")
          outcomes.completed()
          finished.fulfill()
        }
      }
    }
    await fulfillment(of: [finished], timeout: 60)
    XCTAssertEqual(outcomes.recordedEvents.count, total)
  }

  func testPinnedEntriesSurviveEviction() throws {
    let diagram = MermaidErrorImage.make(.timedOut, theme: theme, width: 200, scale: 1)
    var cache = MermaidImageCache(byteLimit: diagram.byteCost * 2)
    let keys = (0..<4).map { request("\($0)", width: 200).key }
    cache.pinned = [keys[0]]
    for key in keys { cache.insert(diagram, for: key) }
    XCTAssertNotNil(cache.value(for: keys[0]), "pinned")
    XCTAssertNotNil(cache.value(for: keys[3]))
    XCTAssertNil(cache.value(for: keys[1]))
    XCTAssertEqual(cache.count, 2)

    var tight = MermaidImageCache(byteLimit: diagram.byteCost - 1)
    tight.insert(diagram, for: keys[0])
    XCTAssertEqual(tight.count, 0)
    tight.pinned = [keys[0]]
    tight.insert(diagram, for: keys[0])
    XCTAssertEqual(tight.count, 1, "a pinned entry is kept even over the limit")
    XCTAssertEqual(tight.pinnedBytes, diagram.byteCost)
    XCTAssertGreaterThan(tight.pinnedBytes, tight.byteLimit)
    tight.pinned = []
    XCTAssertEqual(tight.count, 0, "unpinning trims")
  }

  func testCacheIsBoundedByBytesAndExpires() throws {
    let diagram = MermaidErrorImage.make(.timedOut, theme: theme, width: 200, scale: 1)
    var cache = MermaidImageCache(byteLimit: diagram.byteCost * 2)
    let keys = (0..<3).map { request("\($0)", width: 200).key }
    cache.insert(diagram, for: keys[0])
    cache.insert(diagram, for: keys[1])
    XCTAssertNotNil(cache.value(for: keys[0]))
    cache.insert(diagram, for: keys[2])
    XCTAssertEqual(cache.count, 2)
    XCTAssertNotNil(cache.value(for: keys[0]), "recently used entries survive")
    XCTAssertNil(cache.value(for: keys[1]))
    XCTAssertLessThanOrEqual(cache.totalBytes, cache.byteLimit)

    cache.insert(diagram, for: keys[1], expiry: Date().addingTimeInterval(-1))
    XCTAssertNil(cache.value(for: keys[1]))
  }
}
