import AppKit
import MDViewerCore
import WebKit

public enum WebRendererError: Error, Equatable, LocalizedError {
  case resourcesNotFound(searched: [String])
  case loadFailed(String)
  case unexpectedResult(String)

  public var errorDescription: String? {
    switch self {
    case .resourcesNotFound(let searched):
      return "md-viewer web resources not found; searched: \(searched.joined(separator: ", "))"
    case .loadFailed(let reason):
      return "could not load the markdown viewer page: \(reason)"
    case .unexpectedResult(let function):
      return "unexpected result from viewer function \(function)"
    }
  }
}

@MainActor
public final class WebRenderer: NSObject, WKNavigationDelegate {
  private static let bundleName = "md-viewer_MDViewerWeb.bundle"

  private let viewerURL: URL
  private let window: NSWindow
  private let webView: WKWebView
  private var isLoaded = false
  private var loadTask: Task<Void, Error>?
  private var pendingLoad: CheckedContinuation<Void, Error>?
  private var isBusy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(resources: URL) {
    viewerURL = resources.appendingPathComponent("viewer.html")
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    webView = WKWebView(frame: frame, configuration: configuration)
    window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = webView
    window.orderOut(nil)
    super.init()
    webView.navigationDelegate = self
  }

  public static func resourcesURL() throws -> URL {
    var bundleDirectories = [
      Bundle.main.bundleURL, Bundle(for: WebRenderer.self).bundleURL.deletingLastPathComponent(),
    ]
    if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
      let directory = executable.deletingLastPathComponent()
      bundleDirectories.append(directory)
      bundleDirectories.append(directory.appendingPathComponent("../libexec").standardizedFileURL)
    }
    return try resourcesURL(candidates: bundleDirectories.map { $0.appendingPathComponent(bundleName) })
  }

  static func resourcesURL(candidates: [URL]) throws -> URL {
    var searched: [String] = []
    for candidate in candidates {
      let base = Bundle(url: candidate).flatMap(\.resourceURL) ?? candidate
      let web = base.appendingPathComponent("web")
      if FileManager.default.fileExists(atPath: web.appendingPathComponent("viewer.html").path) {
        return web
      }
      searched.append(candidate.path)
    }
    throw WebRendererError.resourcesNotFound(searched: searched)
  }

  public func render(markdown: String, fileURL: URL, width: CGFloat, theme: Theme) async throws -> CGFloat {
    try await serialized {
      try await loadViewerIfNeeded()
      resize(width: width, height: webView.frame.height)
      let themeArgument: [String: Any] = [
        "dark": theme.dark, "background": theme.background, "foreground": theme.foreground,
      ]
      let result = try await webView.callAsyncJavaScript(
        "return await render(markdown, baseURL, theme)",
        arguments: ["markdown": markdown, "baseURL": fileURL.absoluteString, "theme": themeArgument],
        contentWorld: .page)
      guard let height = (result as? [String: Any])?["height"] as? Double else {
        throw WebRendererError.unexpectedResult("render")
      }
      return CGFloat(height)
    }
  }

  public func snapshot(rect: CGRect) async throws -> NSImage {
    try await serialized {
      resize(width: webView.frame.width, height: rect.height)
      let scrolled = try await call(
        "window.scrollTo(0, y); return window.scrollY", arguments: ["y": Double(rect.minY)])
      let scrollY = CGFloat((scrolled as? Double) ?? 0)
      let configuration = WKSnapshotConfiguration()
      configuration.rect = CGRect(x: rect.minX, y: rect.minY - scrollY, width: rect.width, height: rect.height)
      configuration.snapshotWidth = NSNumber(value: Double(rect.width))
      configuration.afterScreenUpdates = true
      return try await webView.takeSnapshot(configuration: configuration)
    }
  }

  public func links() async throws -> [PageLink] {
    guard let entries = try await serializedCall("return links()") as? [[String: Any]] else {
      throw WebRendererError.unexpectedResult("links")
    }
    return entries.compactMap { entry in
      guard let href = entry["href"] as? String,
        let kind = (entry["kind"] as? String).flatMap(PageLink.Kind.init(rawValue:)),
        let rect = Self.rect(entry)
      else { return nil }
      return PageLink(href: href, kind: kind, rect: rect)
    }
  }

  public func anchorOffset(_ id: String) async throws -> CGFloat? {
    let offset = try await serializedCall("return anchorOffset(id)", arguments: ["id": id])
    return (offset as? Double).map { CGFloat($0) }
  }

  public func search(_ query: String) async throws -> [CGRect] {
    let result = try await serializedCall("return search(query)", arguments: ["query": query])
    guard let entries = result as? [[String: Any]] else {
      throw WebRendererError.unexpectedResult("search")
    }
    return entries.compactMap(Self.rect)
  }

  public func setPoster(index: Int, dataURL: String) async throws {
    _ = try await serializedCall("return setPoster(index, dataURL)", arguments: ["index": index, "dataURL": dataURL])
  }

  func evaluate(_ javaScript: String) async throws -> Any? {
    try await serializedCall("return \(javaScript)")
  }

  public func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    let isInitialLoad =
      !isLoaded && navigationAction.targetFrame?.isMainFrame == true
      && navigationAction.request.url?.standardizedFileURL == viewerURL.standardizedFileURL
    return isInitialLoad ? .allow : .cancel
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isLoaded = true
    finishLoad(with: nil)
  }

  public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finishLoad(with: error)
  }

  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
  ) {
    finishLoad(with: error)
  }

  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    isLoaded = false
    loadTask = nil
    finishLoad(with: WebRendererError.loadFailed("web content process terminated"))
  }

  private func loadViewerIfNeeded() async throws {
    if isLoaded { return }
    let task =
      loadTask
      ?? Task { @MainActor in
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          pendingLoad = continuation
          webView.loadFileURL(viewerURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
      }
    loadTask = task
    do {
      try await task.value
    } catch {
      loadTask = nil
      throw error
    }
  }

  private func finishLoad(with error: Error?) {
    guard let continuation = pendingLoad else { return }
    pendingLoad = nil
    if let error {
      continuation.resume(throwing: WebRendererError.loadFailed(error.localizedDescription))
    } else {
      continuation.resume()
    }
  }

  private func serialized<T>(_ operation: () async throws -> T) async throws -> T {
    if isBusy {
      await withCheckedContinuation { waiters.append($0) }
    } else {
      isBusy = true
    }
    defer { releaseTurn() }
    return try await operation()
  }

  private func releaseTurn() {
    if waiters.isEmpty {
      isBusy = false
    } else {
      waiters.removeFirst().resume()
    }
  }

  private func serializedCall(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
    try await serialized { try await call(body, arguments: arguments) }
  }

  private func call(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
    try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
  }

  private func resize(width: CGFloat, height: CGFloat) {
    let size = NSSize(width: width, height: height)
    window.setContentSize(size)
    webView.setFrameSize(size)
  }

  private static func rect(_ entry: [String: Any]) -> CGRect? {
    guard let x = entry["x"] as? Double, let y = entry["y"] as? Double,
      let width = entry["width"] as? Double, let height = entry["height"] as? Double
    else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
  }
}
