import AppKit
import CoreGraphics
import Foundation
import MDViewerCore
import WebKit
import XCTest

@testable import MDViewerMermaid

@MainActor
final class MermaidPageTests: XCTestCase {
  private let theme = MermaidTheme(palette: .fallback(dark: true))

  private func request(_ code: String) -> MermaidRequest {
    MermaidRequest(code: code, theme: theme, width: 600, scale: 1)
  }

  private func evaluate(_ renderer: MermaidRenderer, _ javaScript: String) async throws -> String? {
    try await renderer.engine.evaluateForTesting(javaScript)
  }

  func testHungPageIsReclaimedAndTheNextDiagramRenders() async throws {
    let renderer = MermaidRenderer(configuration: .init(diagramTimeout: 2))
    let first = await render(renderer, request("flowchart LR\n  A --> B"))
    XCTAssertNil(first.failure)
    weak let hungWebView = renderer.engine.webViewForTesting
    XCTAssertNotNil(hungWebView)

    renderer.engine.hangForTesting()
    let stuck = await render(renderer, request("flowchart LR\n  C --> D"))
    XCTAssertEqual(stuck.failure, .timedOut)
    XCTAssertFalse(renderer.engine.isRunning)
    try await waitUntil(timeout: 10) { hungWebView == nil }

    let next = await render(renderer, request("flowchart LR\n  E --> F"))
    XCTAssertNil(next.failure)
    XCTAssertEqual(renderer.engine.startCount, 2)
  }

  func testCrashedWebContentRecovers() async throws {
    let renderer = MermaidRenderer()
    let first = await render(renderer, request("flowchart LR\n  A --> B"))
    XCTAssertNil(first.failure)

    let inFlight = Task { @MainActor in
      try await renderer.engine.evaluateForTesting(
        "return await new Promise(resolve => setTimeout(() => resolve(1), 3000))")
    }
    try await pause(0.1)
    let started = Date()
    renderer.engine.simulateCrashForTesting()
    do {
      _ = try await inFlight.value
      XCTFail("the in-flight call should fail when the process terminates")
    } catch {
      XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    let next = await render(renderer, request("flowchart LR\n  C --> D"))
    XCTAssertNil(next.failure)
    XCTAssertEqual(renderer.engine.startCount, 2)
  }

  func testPageIsLockedDown() async throws {
    let renderer = MermaidRenderer()
    let first = await render(renderer, request("flowchart LR\n  A --> B"))
    XCTAssertNil(first.failure)

    let policy = try await evaluate(
      renderer, "return document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').content")
    for directive in ["default-src 'none'", "script-src file:", "connect-src 'none'", "img-src data:"] {
      XCTAssertTrue(policy?.contains(directive) == true, directive)
    }

    for target in ["mermaid.min.js", "file:///etc/hosts"] {
      let read = try await evaluate(
        renderer, "return await fetch('\(target)').then(() => 'read', () => 'blocked')")
      XCTAssertEqual(read, "blocked", target)
    }

    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("mermaid-outside-\(UUID()).png")
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    try XCTUnwrap(bitmap?.representation(using: .png, properties: [:])).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    let image = try await evaluate(
      renderer,
      """
      return await new Promise(resolve => {
        const image = new Image();
        image.onload = () => resolve('loaded');
        image.onerror = () => resolve('blocked');
        image.src = '\(outside.absoluteString)';
      })
      """)
    XCTAssertEqual(image, "blocked")

    let inline = try await evaluate(
      renderer,
      """
      document.body.insertAdjacentHTML('beforeend', '<img src="data:," onerror="window.__inline = 1">');
      const script = document.createElement('script');
      script.textContent = 'window.__script = 1';
      document.body.appendChild(script);
      await new Promise(resolve => setTimeout(resolve, 200));
      return typeof window.__inline + ' ' + typeof window.__script
      """)
    XCTAssertEqual(inline, "undefined undefined")

    let popup = try await evaluate(renderer, "return String(window.open('https://example.com'))")
    XCTAssertEqual(popup, "null")
    for target in ["file:///etc/hosts", "https://example.com/"] {
      _ = try await evaluate(renderer, "location.href = '\(target)'; return 1")
      try await pause(0.3)
      let location = try await evaluate(renderer, "return location.href")
      XCTAssertTrue(location?.hasSuffix("/mermaid/mermaid.html") == true, location ?? "nil")
    }
    XCTAssertEqual(renderer.engine.startCount, 1, "blocked navigation leaves the page usable")

    let next = await render(renderer, request("flowchart LR\n  C --> D"))
    XCTAssertNil(next.failure)
  }

  func testHostileInputStaysInert() async throws {
    let renderer = MermaidRenderer()
    let hostile = [
      """
      %%{init: {"securityLevel": "loose"}}%%
      flowchart LR
        A[Start] --> B[Next]
        click A callback "Tooltip"
        click B href "javascript:window.__pwned=1"
      """,
      """
      flowchart LR
        A["<script>window.__pwned=1</script>"] --> B
      """,
      """
      flowchart LR
        A["<img src=x onerror='window.__pwned=1'>"] --> B["<b>bold</b> <a href='javascript:window.__pwned=1'>x</a>"]
      """,
      """
      sequenceDiagram
        Alice->>Bob: <script>window.__pwned=1</script>
      """,
    ]
    for code in hostile {
      let diagram = await render(renderer, request(code))
      XCTAssertNil(diagram.failure, code)
      let pwned = try await evaluate(renderer, "return typeof window.__pwned")
      XCTAssertEqual(pwned, "undefined", code)
      let level = try await evaluate(renderer, "return mermaid.mermaidAPI.getConfig().securityLevel")
      XCTAssertEqual(level, "strict", code)
      let unsafe = try await evaluate(
        renderer,
        """
        return [...document.querySelectorAll('#stage *')].filter(e =>
          ['script', 'iframe', 'object', 'embed'].includes(e.localName) ||
          [...e.attributes].some(a => a.name.toLowerCase().startsWith('on') || /javascript:/i.test(a.value))
        ).length
        """)
      XCTAssertEqual(unsafe, "0", code)
    }
  }
}
