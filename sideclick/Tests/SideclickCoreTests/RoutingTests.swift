import Foundation
import SideclickCore
import Testing

struct RoutingTests {
  let link = URL(string: "https://example.com/page")!
  let brave = ["http": "com.brave.browser", "https": "com.brave.browser"]

  @Test(arguments: [
    (rexBundleID as String?, false, Route.pane),
    (rexBundleID, true, .forward(bundleID: "com.brave.browser")),
    ("com.tinyspeck.slackmacgap", false, .forward(bundleID: "com.brave.browser")),
    ("com.tinyspeck.slackmacgap", true, .forward(bundleID: "com.brave.browser")),
    (nil, false, .forward(bundleID: "com.brave.browser")),
    (nil, true, .forward(bundleID: "com.brave.browser")),
  ])
  func routesBySenderAndOption(sender: String?, optionHeld: Bool, expected: Route) {
    #expect(
      route(
        url: link, senderBundleID: sender, optionHeld: optionHeld, previousHandlers: brave, isInstalled: { _ in true })
        == expected)
  }

  @Test func forwardsToSafariWhenPreviousBrowserIsGone() {
    #expect(
      route(url: link, senderBundleID: nil, optionHeld: false, previousHandlers: brave, isInstalled: { _ in false })
        == .forward(bundleID: safariBundleID))
  }

  @Test func forwardsToSafariWhenNothingWasRecorded() {
    #expect(forwardTarget(scheme: "https", previousHandlers: [:], isInstalled: { _ in true }) == safariBundleID)
  }

  @Test func neverForwardsToItself() {
    let previous = ["https": routerBundleID]
    #expect(forwardTarget(scheme: "https", previousHandlers: previous, isInstalled: { _ in true }) == safariBundleID)
  }

  @Test func usesTheOtherSchemesBrowserWhenOneIsMissing() {
    let previous = ["http": "com.brave.browser"]
    #expect(
      forwardTarget(scheme: "https", previousHandlers: previous, isInstalled: { _ in true }) == "com.brave.browser")
  }

  @Test func plainHTTPFromRexOpensInAPane() {
    let plain = URL(string: "http://localhost:5173")!
    #expect(
      route(
        url: plain, senderBundleID: rexBundleID, optionHeld: false, previousHandlers: brave, isInstalled: { _ in true })
        == .pane)
  }

  @Test func otherSchemesFromRexAreForwarded() {
    let mail = URL(string: "mailto:someone@example.com")!
    #expect(
      route(
        url: mail, senderBundleID: rexBundleID, optionHeld: false, previousHandlers: brave, isInstalled: { _ in true })
        == .forward(bundleID: "com.brave.browser"))
  }

  @Test(arguments: [
    (Int32?.some(42), true, true),
    (nil, true, true),
    (Int32?.some(7), true, false),
    (Int32?.some(42), false, false),
    (nil, false, false),
  ])
  func reactivatesOnlyWhenSideclickStillHoldsFocus(frontmost: Int32?, senderRunning: Bool, expected: Bool) {
    #expect(shouldReactivate(frontmostPID: frontmost, ownPID: 42, senderRunning: senderRunning) == expected)
  }
}
