import AppKit
import WebKit

struct MermaidLayout: Sendable {
  var width: CGFloat
  var height: CGFloat
  var pixelRatio: CGFloat
}

enum MermaidRenderReply: Sendable {
  case diagram(MermaidLayout)
  case error(String)
}

struct MermaidPageError: Error, Equatable {
  var reason: String
}

struct ScriptValue: @unchecked Sendable {
  var value: Any?
}

struct SnapshotImage: @unchecked Sendable {
  var image: CGImage
}

@MainActor
final class MermaidPage: NSObject, WKNavigationDelegate {
  let pageURL: URL
  private let window: NSWindow
  private var webView: WKWebView?
  private var pendingLoad: CheckedContinuation<Void, Error>?
  private var calls: [Int: CheckedContinuation<ScriptValue, Error>] = [:]
  private var snapshots: [Int: CheckedContinuation<SnapshotImage, Error>] = [:]
  private var nextCall = 0
  private var isLoaded = false
  private(set) var isUsable = true

  init(pageURL: URL) {
    self.pageURL = pageURL
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.suppressesIncrementalRendering = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    let webView = WKWebView(frame: frame, configuration: configuration)
    self.webView = webView
    window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = webView
    window.orderOut(nil)
    super.init()
    webView.navigationDelegate = self
  }

  var webViewForTesting: WKWebView? { webView }

  func load() async throws {
    if isLoaded { return }
    guard pendingLoad == nil else { throw MermaidPageError(reason: "page is already loading") }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      pendingLoad = continuation
      startLoad()
    }
    let ready = try await call("return typeof mermaid === 'object' && typeof renderDiagram === 'function'")
    guard (ready.value as? Bool) == true else { throw MermaidPageError(reason: "mermaid did not load") }
  }

  func render(source: String, theme: MermaidTheme) async throws -> MermaidRenderReply {
    var variables: [String: Any] = theme.variables
    variables["darkMode"] = theme.dark
    let result = try await call(
      "return await renderDiagram(source, theme)",
      arguments: [
        "source": source,
        "theme": ["background": theme.background.description, "variables": variables] as [String: Any],
      ])
    guard let reply = result.value as? [String: Any] else { throw MermaidPageError(reason: "unexpected reply") }
    if let message = reply["error"] as? String { return .error(message) }
    guard let width = reply["width"] as? Double, let height = reply["height"] as? Double,
      let ratio = reply["pixelRatio"] as? Double, width.isFinite, height.isFinite, width > 0, height > 0
    else { throw MermaidPageError(reason: "unexpected diagram size") }
    return .diagram(MermaidLayout(width: width, height: height, pixelRatio: max(ratio, 0.5)))
  }

  func snapshot(displaySize: CGSize) async throws -> SnapshotImage {
    resize(to: NSSize(width: displaySize.width.rounded(.up) + 1, height: displaySize.height.rounded(.up) + 1))
    let presented = try await call(
      "return presentDiagram(width, height)",
      arguments: ["width": Double(displaySize.width), "height": Double(displaySize.height)])
    guard (presented.value as? Bool) == true else { throw MermaidPageError(reason: "diagram vanished") }
    return try await withCheckedThrowingContinuation { continuation in
      let id = register(snapshot: continuation)
      startSnapshot(id, displaySize: displaySize)
    }
  }

  func evaluate(_ javaScript: String) async throws -> String? {
    try await call(javaScript).value.map { "\($0)" }
  }

  func startHangForTesting() {
    webView?.callAsyncJavaScript("while (true) {}", arguments: [:], in: nil, in: .page) { _ in }
  }

  func close() {
    isUsable = false
    if let webView {
      webView.navigationDelegate = nil
      webView.stopLoading()
    }
    window.contentView = nil
    window.close()
    webView = nil
    failPending(MermaidPageError(reason: "page closed"))
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    let isInitialLoad =
      !isLoaded && navigationAction.targetFrame?.isMainFrame == true
      && navigationAction.request.url?.standardizedFileURL == pageURL.standardizedFileURL
    return isInitialLoad ? .allow : .cancel
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isLoaded = true
    if let continuation = pendingLoad {
      pendingLoad = nil
      continuation.resume()
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failInitialLoad(error)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
  ) {
    failInitialLoad(error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    isUsable = false
    failPending(MermaidPageError(reason: "web content process terminated"))
  }

  private func failInitialLoad(_ error: Error) {
    guard !isLoaded else { return }
    isUsable = false
    failPending(MermaidPageError(reason: error.localizedDescription))
  }

  private func call(_ body: String, arguments: [String: Any] = [:]) async throws -> ScriptValue {
    guard isUsable else { throw MermaidPageError(reason: "page closed") }
    return try await withCheckedThrowingContinuation { continuation in
      let id = register(call: continuation)
      startCall(id, body: body, arguments: arguments)
    }
  }

  private func register(call continuation: CheckedContinuation<ScriptValue, Error>) -> Int {
    nextCall += 1
    calls[nextCall] = continuation
    return nextCall
  }

  private func register(snapshot continuation: CheckedContinuation<SnapshotImage, Error>) -> Int {
    nextCall += 1
    snapshots[nextCall] = continuation
    return nextCall
  }

  private func startLoad() {
    guard let webView else { return failPending(MermaidPageError(reason: "page closed")) }
    webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
  }

  private func startCall(_ id: Int, body: String, arguments: [String: Any]) {
    guard let webView else { return finishCall(id, .failure(MermaidPageError(reason: "page closed"))) }
    webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { [weak self] result in
      let value = result.map { ScriptValue(value: $0) }
      MainActor.assumeIsolated { self?.finishCall(id, value) }
    }
  }

  private func startSnapshot(_ id: Int, displaySize: CGSize) {
    guard let webView else {
      return finishSnapshot(id, .failure(MermaidPageError(reason: "page closed")))
    }
    let configuration = WKSnapshotConfiguration()
    configuration.rect = CGRect(origin: .zero, size: displaySize)
    configuration.snapshotWidth = NSNumber(value: Double(displaySize.width))
    configuration.afterScreenUpdates = true
    webView.takeSnapshot(with: configuration) { [weak self] image, error in
      let result: Result<SnapshotImage, Error>
      if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        result = .success(SnapshotImage(image: cgImage))
      } else {
        result = .failure(error ?? MermaidPageError(reason: "empty snapshot"))
      }
      MainActor.assumeIsolated { self?.finishSnapshot(id, result) }
    }
  }

  private func resize(to size: NSSize) {
    window.setContentSize(size)
    webView?.setFrameSize(size)
  }

  private func finishCall(_ id: Int, _ result: Result<ScriptValue, Error>) {
    calls.removeValue(forKey: id)?.resume(with: result)
  }

  private func finishSnapshot(_ id: Int, _ result: Result<SnapshotImage, Error>) {
    snapshots.removeValue(forKey: id)?.resume(with: result)
  }

  private func failPending(_ error: MermaidPageError) {
    if let continuation = pendingLoad {
      pendingLoad = nil
      continuation.resume(throwing: error)
    }
    let pendingCalls = calls
    let pendingSnapshots = snapshots
    calls = [:]
    snapshots = [:]
    for continuation in pendingCalls.values { continuation.resume(throwing: error) }
    for continuation in pendingSnapshots.values { continuation.resume(throwing: error) }
  }
}
