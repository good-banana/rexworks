import XCTest

@testable import MDViewerCore

final class OpenPlanTests: XCTestCase {
  private let caller = PaneTarget(session: "s", window: "w", block: "block:caller")
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func file(_ name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data("# \(name)".utf8).write(to: url)
    return url
  }

  private func preview(_ block: String, showing file: URL?, openedAt: Double, opener: String? = "block:caller")
    -> PreviewPane
  {
    PreviewPane(block: block, state: ViewerState(file: file?.path, openedAt: openedAt, opener: opener))
  }

  private func below(_ block: String) -> OpenOutcome {
    .split(.below(PaneTarget(session: "s", window: "w", block: block)))
  }

  func testFirstPreviewOpensBesideTheCallingPane() throws {
    let a = try file("a.md")
    for policy in [OpenPolicy.perFile, .new, .replace] {
      XCTAssertEqual(planOpen(target: caller, file: a, previews: [], policy: policy), .split(.beside(caller)))
    }
    XCTAssertEqual(
      planOpen(target: PaneTarget(session: "s", window: nil, block: nil), file: a, previews: [], policy: .perFile),
      .newTab(session: "s"))
    XCTAssertEqual(
      planOpen(target: PaneTarget(session: "s", window: "w", block: nil), file: a, previews: [], policy: .perFile),
      .newTab(session: "s"))
  }

  func testThePreviewShowingTheSameFileIsReused() throws {
    let a = try file("a.md")
    let b = try file("b.md")
    let previews = [preview("block:a", showing: a, openedAt: 1), preview("block:b", showing: b, openedAt: 2)]
    XCTAssertEqual(
      planOpen(target: caller, file: a, previews: previews, policy: .perFile),
      .reused(block: "block:a", message: a.path))
  }

  func testTheSameFileMatchesThroughSymlinksAndDotSegments() throws {
    let a = try file("a.md")
    let link = directory.appendingPathComponent("link.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
    let previews = [preview("block:a", showing: link, openedAt: 1)]
    XCTAssertEqual(
      planOpen(target: caller, file: a, previews: previews, policy: .perFile),
      .reused(block: "block:a", message: link.path))
    let dotted = URL(fileURLWithPath: directory.path + "/./sub/../a.md")
    XCTAssertEqual(
      planOpen(target: caller, file: dotted, previews: previews, policy: .perFile),
      .reused(block: "block:a", message: link.path))
  }

  func testADifferentFileGetsANewPaneBelowTheNewestPreview() throws {
    let a = try file("a.md")
    let b = try file("b.md")
    let c = try file("c.md")
    let previews = [preview("block:b", showing: b, openedAt: 20), preview("block:a", showing: a, openedAt: 10)]
    XCTAssertEqual(planOpen(target: caller, file: c, previews: previews, policy: .perFile), below("block:b"))
  }

  func testPreviewsThatDoNotAnswerAreOlderThanAnyThatDo() throws {
    let a = try file("a.md")
    let c = try file("c.md")
    let previews = [
      preview("block:a", showing: a, openedAt: 5), PreviewPane(block: "block:old", state: nil),
    ]
    XCTAssertEqual(planOpen(target: caller, file: c, previews: previews, policy: .perFile), below("block:a"))
    let silent = [PreviewPane(block: "block:first", state: nil), PreviewPane(block: "block:second", state: nil)]
    XCTAssertEqual(planOpen(target: caller, file: c, previews: silent, policy: .perFile), below("block:second"))
  }

  func testAFileReachedThroughAnInViewerLinkCountsAsShown() throws {
    let a = try file("a.md")
    let b = try file("b.md")
    let navigated = [preview("block:p", showing: b, openedAt: 1)]
    XCTAssertEqual(
      planOpen(target: caller, file: b, previews: navigated, policy: .perFile),
      .reused(block: "block:p", message: b.path))
    XCTAssertEqual(planOpen(target: caller, file: a, previews: navigated, policy: .perFile), below("block:p"))
  }

  private final class FakeClock {
    var now = Date(timeIntervalSince1970: 1000)
    var slept: TimeInterval = 0

    func sleep(_ seconds: TimeInterval) {
      slept += seconds
      now += seconds
    }

    func previews(_ blocks: [String], probe: (String) -> PreviewProbe) -> [PreviewPane] {
      reachablePreviews(blocks, now: { self.now }, sleep: sleep, probe: probe)
    }
  }

  func testAStartingPreviewIsRetriedUntilItAnswers() throws {
    let a = try file("a.md")
    let state = ViewerState(file: a.path, openedAt: 1, opener: "block:caller")
    let clock = FakeClock()
    var probes: [String: Int] = [:]
    let previews = clock.previews(["block:starting", "block:old"]) { block in
      probes[block, default: 0] += 1
      if block == "block:old" { return .silent }
      return probes[block]! < 4 ? .unreachable : .answered(state)
    }
    XCTAssertEqual(
      previews, [PreviewPane(block: "block:starting", state: state), PreviewPane(block: "block:old", state: nil)])
    XCTAssertEqual(probes, ["block:starting": 4, "block:old": 1])
    XCTAssertEqual(clock.slept, 3 * previewProbeInterval, accuracy: 1e-6)
    XCTAssertEqual(
      planOpen(target: caller, file: a, previews: previews, policy: .perFile),
      .reused(block: "block:starting", message: a.path))
  }

  func testAPreviewThatNeverAnswersBecomesAnAnchorAfterTheStartupWindow() throws {
    let a = try file("a.md")
    let clock = FakeClock()
    var attempts = 0
    let previews = clock.previews(["block:starting"]) { _ in
      attempts += 1
      return .unreachable
    }
    XCTAssertEqual(previews, [PreviewPane(block: "block:starting", state: nil)])
    XCTAssertEqual(clock.slept, previewStartupWindow, accuracy: 1e-6)
    XCTAssertGreaterThan(attempts, 2)
    for policy in [OpenPolicy.perFile, .new] {
      XCTAssertEqual(planOpen(target: caller, file: a, previews: previews, policy: policy), below("block:starting"))
    }
    XCTAssertEqual(
      planOpen(target: caller, file: a, previews: previews, policy: .replace),
      .reused(block: "block:starting", message: a.path))
  }

  func testReplacingIntoAPreviewThatStillCannotTakeMessagesStacksBelowIt() throws {
    let a = try file("a.md")
    let b = try file("b.md")
    var delivered: [String] = []
    let starting = PreviewPane(block: "block:starting", state: nil)
    let outcome = resolveOpen(target: caller, file: a, previews: [starting], policy: .replace) { block, _ in
      delivered.append(block)
      return false
    }
    XCTAssertEqual(delivered, ["block:starting"])
    XCTAssertEqual(outcome, below("block:starting"))
    delivered = []
    let mixed = resolveOpen(
      target: caller, file: a, previews: [preview("block:old", showing: b, openedAt: 1), starting], policy: .replace
    ) { block, _ in
      delivered.append(block)
      return block == "block:old"
    }
    XCTAssertEqual(delivered, ["block:old"])
    XCTAssertEqual(mixed, .reused(block: "block:old", message: a.path))
  }

  func testReachablePreviewsAreProbedOnceWithoutWaiting() throws {
    let state = ViewerState(file: "/a.md", openedAt: 1, opener: nil)
    let clock = FakeClock()
    var attempts = 0
    let previews = clock.previews(["block:live", "block:old"]) {
      attempts += 1
      return $0 == "block:live" ? .answered(state) : .silent
    }
    XCTAssertEqual(
      previews, [PreviewPane(block: "block:live", state: state), PreviewPane(block: "block:old", state: nil)])
    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(clock.slept, 0)
    XCTAssertEqual(clock.previews([]) { _ in .unreachable }, [])
  }

  func testTheStartupWindowIsBoundedInRealTime() {
    let started = Date()
    let previews = reachablePreviews(["block:a", "block:b"], startupWindow: 0.2) { _ in .unreachable }
    XCTAssertEqual(previews.map(\.state), [nil, nil])
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.2)
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
  }

  func testPreviewsLeaveRexWhenTheirViewerExits() {
    let placement = SplitPlacement.beside(caller)
    let file = URL(fileURLWithPath: "/a.md")
    for arguments in [
      splitArguments(placement: placement, file: file, mdViewer: "/bin/md-viewer"),
      tabArguments(session: "s", file: file, mdViewer: "/bin/md-viewer"),
    ] {
      XCTAssertTrue(arguments.contains("--shell=none"))
      XCTAssertFalse(arguments.contains { $0.hasPrefix("--keep-open") })
    }
  }

  func testAFailedDeliveryFallsBackWithoutThatPreview() throws {
    let a = try file("a.md")
    let b = try file("b.md")
    let previews = [preview("block:old", showing: b, openedAt: 1), preview("block:dead", showing: a, openedAt: 2)]
    var delivered: [String] = []
    let outcome = resolveOpen(target: caller, file: a, previews: previews, policy: .perFile) { block, _ in
      delivered.append(block)
      return false
    }
    XCTAssertEqual(delivered, ["block:dead"])
    XCTAssertEqual(outcome, below("block:old"))
    var attempts = 0
    let alone = resolveOpen(
      target: caller, file: a, previews: [preview("block:dead", showing: a, openedAt: 2)], policy: .replace
    ) { _, _ in
      attempts += 1
      return false
    }
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(alone, .split(.beside(caller)))
  }

  func testASuccessfulDeliveryReusesThePreview() throws {
    let a = try file("a.md")
    var messages: [String] = []
    let outcome = resolveOpen(
      target: caller, file: a, previews: [preview("block:p", showing: a, openedAt: 1)], policy: .perFile
    ) { _, message in
      messages.append(message)
      return true
    }
    XCTAssertEqual(outcome, .reused(block: "block:p", message: a.path))
    XCTAssertEqual(messages, [a.path])
  }

  func testNewAlwaysOpensAPaneEvenWhenTheFileIsShown() throws {
    let a = try file("a.md")
    let previews = [preview("block:a", showing: a, openedAt: 1)]
    XCTAssertEqual(planOpen(target: caller, file: a, previews: previews, policy: .new), below("block:a"))
  }

  func testReplacePrefersThePreviewThisPaneOpenedLast() throws {
    let a = try file("a.md")
    let b = try file("b.md")
    let previews = [
      preview("block:mine-old", showing: a, openedAt: 1),
      preview("block:mine", showing: a, openedAt: 2),
      preview("block:other", showing: a, openedAt: 3, opener: "block:elsewhere"),
    ]
    XCTAssertEqual(
      planOpen(target: caller, file: b, previews: previews, policy: .replace),
      .reused(block: "block:mine", message: b.path))
  }

  func testReplaceFallsBackToTheNewestPreviewInTheTab() throws {
    let b = try file("b.md")
    let previews = [
      preview("block:x", showing: nil, openedAt: 1, opener: "block:elsewhere"),
      preview("block:y", showing: nil, openedAt: 2, opener: nil),
    ]
    XCTAssertEqual(
      planOpen(target: caller, file: b, previews: previews, policy: .replace),
      .reused(block: "block:y", message: b.path))
    let unfocused = PaneTarget(session: "s", window: "w", block: nil)
    XCTAssertEqual(
      planOpen(target: unfocused, file: b, previews: previews, policy: .replace),
      .reused(block: "block:y", message: b.path))
  }

  func testOpenArgumentsParseFlags() {
    XCTAssertEqual(try OpenArguments.parse(["a.md"]).get(), OpenArguments(file: "a.md", choice: .configured))
    XCTAssertEqual(try OpenArguments.parse(["--new", "a.md"]).get(), OpenArguments(file: "a.md", choice: .new))
    XCTAssertEqual(try OpenArguments.parse(["a.md", "--replace"]).get(), OpenArguments(file: "a.md", choice: .replace))
    XCTAssertEqual(
      try OpenArguments.parse(["--new", "--new", "a.md"]).get(), OpenArguments(file: "a.md", choice: .new))
    XCTAssertEqual(try OpenArguments.parse(["--", "--new.md"]).get(), OpenArguments(file: "--new.md"))
  }

  func testOpenArgumentsRejectUnknownConflictingAndMissing() {
    func failure(_ arguments: [String]) -> String? {
      guard case .failure(let error) = OpenArguments.parse(arguments) else { return nil }
      return error.description
    }
    XCTAssertEqual(failure(["--newer", "a.md"]), "unknown option: --newer\n\(openUsage)")
    XCTAssertEqual(failure(["-n", "a.md"]), "unknown option: -n\n\(openUsage)")
    XCTAssertEqual(
      failure(["--new", "--replace", "a.md"]), "--new and --replace cannot be used together\n\(openUsage)")
    XCTAssertEqual(
      failure(["--replace", "a.md", "--new"]), "--new and --replace cannot be used together\n\(openUsage)")
    XCTAssertEqual(failure([]), openUsage)
    XCTAssertEqual(failure(["--new"]), openUsage)
    XCTAssertEqual(failure(["a.md", "b.md"]), openUsage)
  }

  func testFlagsOverrideTheSettingAndClicksFollowIt() {
    let click = OpenArguments(file: "/tmp/a.md")
    XCTAssertEqual(click.policy(.perFile), .perFile)
    XCTAssertEqual(click.policy(.single), .replace)
    for mode in [PreviewMode.perFile, .single] {
      XCTAssertEqual(OpenArguments(file: "a.md", choice: .new).policy(mode), .new)
      XCTAssertEqual(OpenArguments(file: "a.md", choice: .replace).policy(mode), .replace)
    }
  }

  func testSingleModeSwitchesTheTabsPreviewToTheClickedFile() throws {
    let a = try file("a.md")
    let b = try file("b.md")
    let focused = PaneTarget(session: "s", window: "w", block: "block:focused")
    let previews = [preview("block:p", showing: a, openedAt: 1, opener: "block:caller")]
    let policy = OpenArguments(file: b.path).policy(.single)
    XCTAssertEqual(
      planOpen(target: focused, file: b, previews: previews, policy: policy), .reused(block: "block:p", message: b.path)
    )
    XCTAssertEqual(
      planOpen(target: focused, file: b, previews: previews, policy: OpenArguments(file: b.path).policy(.perFile)),
      below("block:p"))
  }
}
