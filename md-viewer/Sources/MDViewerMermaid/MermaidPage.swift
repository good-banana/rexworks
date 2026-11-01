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

struct SnapshotImage: @unchecked Sendable {
  var image: CGImage
}

@MainActor
final class MermaidPage: NSObject, WKNavigationDelegate {
  let pageURL: URL
  private let window: NSWindow
  private let webView: WKWebView
  private var pendingLoad: CheckedContinuation<Void, Error>?
  private var isLoaded = false
  private(set) var isUsable = true

  init(pageURL: URL) {
    self.pageURL = pageURL
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.suppressesIncrementalRendering = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    webView = WKWebView(frame: frame, configuration: configuration)
    window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = webView
    window.orderOut(nil)
    super.init()
    webView.navigationDelegate = self
  }

  func load() async throws {
    if isLoaded { return }
    guard pendingLoad == nil else { throw MermaidPageError(reason: "page is already loading") }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      pendingLoad = continuation
      webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }
    let ready = try await webView.callAsyncJavaScript(
      "return typeof mermaid === 'object' && typeof renderDiagram === 'function'", arguments: [:],
      contentWorld: .page)
    guard (ready as? Bool) == true else { throw MermaidPageError(reason: "mermaid did not load") }
  }

  func render(source: String, theme: MermaidTheme) async throws -> MermaidRenderReply {
    var variables: [String: Any] = theme.variables
    variables["darkMode"] = theme.dark
    let result = try await webView.callAsyncJavaScript(
      "return await renderDiagram(source, theme)",
      arguments: [
        "source": source,
        "theme": ["background": theme.background.description, "variables": variables] as [String: Any],
      ],
      contentWorld: .page)
    guard let reply = result as? [String: Any] else { throw MermaidPageError(reason: "unexpected reply") }
    if let message = reply["error"] as? String { return .error(message) }
    guard let width = reply["width"] as? Double, let height = reply["height"] as? Double,
      let ratio = reply["pixelRatio"] as? Double, width.isFinite, height.isFinite, width > 0, height > 0
    else { throw MermaidPageError(reason: "unexpected diagram size") }
    return .diagram(MermaidLayout(width: width, height: height, pixelRatio: max(ratio, 0.5)))
  }

  func snapshot(displaySize: CGSize) async throws -> SnapshotImage {
    let viewSize = NSSize(width: displaySize.width.rounded(.up) + 1, height: displaySize.height.rounded(.up) + 1)
    window.setContentSize(viewSize)
    webView.setFrameSize(viewSize)
    let presented = try await webView.callAsyncJavaScript(
      "return presentDiagram(width, height)",
      arguments: ["width": Double(displaySize.width), "height": Double(displaySize.height)], contentWorld: .page)
    guard (presented as? Bool) == true else { throw MermaidPageError(reason: "diagram vanished") }
    let configuration = WKSnapshotConfiguration()
    configuration.rect = CGRect(origin: .zero, size: displaySize)
    configuration.snapshotWidth = NSNumber(value: Double(displaySize.width))
    configuration.afterScreenUpdates = true
    let image = try await webView.takeSnapshot(configuration: configuration)
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw MermaidPageError(reason: "empty snapshot")
    }
    return SnapshotImage(image: cgImage)
  }

  func evaluate(_ javaScript: String) async throws -> String? {
    let result = try await webView.callAsyncJavaScript(javaScript, arguments: [:], contentWorld: .page)
    return result.map { "\($0)" }
  }

  func close() {
    isUsable = false
    webView.navigationDelegate = nil
    webView.stopLoading()
    window.contentView = nil
    window.close()
    finishLoad(with: MermaidPageError(reason: "page closed"))
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
    finishLoad(with: nil)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    isUsable = false
    finishLoad(with: error)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
  ) {
    isUsable = false
    finishLoad(with: error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    isUsable = false
    finishLoad(with: MermaidPageError(reason: "web content process terminated"))
  }

  private func finishLoad(with error: Error?) {
    guard let continuation = pendingLoad else { return }
    pendingLoad = nil
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }
}
