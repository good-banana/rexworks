import AppKit
import CoreGraphics
import Foundation
import MDViewerCore
import WebKit

enum MermaidOutcome: Sendable {
  case rendered(MermaidDiagram)
  case failed(MermaidFailure)
}

struct MermaidJob: Sendable {
  var request: MermaidRequest
  var deadline: TimeInterval
  var isWanted: @Sendable () -> Bool
  var abandoned: @Sendable () -> Void
  var sizeReady: @Sendable (CGSize) -> Void
  var finished: @Sendable (MermaidOutcome) -> Void
}

struct MermaidTimeout: Error {}

struct MermaidLoadFailure: Error {
  var reason: String
}

@MainActor
final class MermaidEngine {
  let configuration: MermaidRenderer.Configuration
  let pageURL: URL?
  private var jobs: [MermaidJob] = []
  private var isBusy = false
  private var page: MermaidPage?
  private var idleShutdown: DispatchWorkItem?
  private var startNotBefore: Date?
  private(set) var startCount = 0
  private(set) var startedJobs: [String] = []

  nonisolated init(configuration: MermaidRenderer.Configuration, pageURL: URL?) {
    self.configuration = configuration
    self.pageURL = pageURL
  }

  var isRunning: Bool { page != nil }
  var webViewForTesting: WKWebView? { page?.webViewForTesting }

  func enqueue(_ job: MermaidJob) {
    idleShutdown?.cancel()
    idleShutdown = nil
    jobs.append(job)
    pump()
  }

  func shutDown() {
    idleShutdown?.cancel()
    idleShutdown = nil
    page?.close()
    page = nil
  }

  func evaluateForTesting(_ javaScript: String) async throws -> String? {
    try await page?.evaluate(javaScript)
  }

  func hangForTesting() {
    page?.startHangForTesting()
  }

  func simulateCrashForTesting() {
    guard let page, let webView = page.webViewForTesting else { return }
    page.webViewWebContentProcessDidTerminate(webView)
  }

  private func pump() {
    guard !isBusy else { return }
    while let job = jobs.popLast() {
      guard job.isWanted() else {
        job.abandoned()
        continue
      }
      isBusy = true
      startedJobs.append(job.request.code)
      Task { @MainActor in
        let outcome = await self.run(job)
        job.finished(outcome)
        self.isBusy = false
        self.pump()
      }
      return
    }
    scheduleIdleShutdown()
  }

  private func scheduleIdleShutdown() {
    guard page != nil else { return }
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.isBusy, self.jobs.isEmpty else { return }
        self.shutDown()
      }
    }
    idleShutdown = work
    DispatchQueue.main.asyncAfter(deadline: .now() + configuration.idleTimeout, execute: work)
  }

  private enum Rendered: Sendable {
    case syntax(String)
    case snapshot(SnapshotImage, size: CGSize, pixels: MermaidRaster.PixelSize)
  }

  private func run(_ job: MermaidJob) async -> MermaidOutcome {
    let request = job.request
    let state = JobState()
    defer { state.isFinished = true }
    let page: MermaidPage
    do {
      page = try await loadedPage()
    } catch {
      let reason = (error as? MermaidLoadFailure)?.reason ?? error.localizedDescription
      failQueuedJobs(reason)
      return .failed(.unavailable(reason))
    }
    do {
      let rendered = try await withDeadline(job.deadline) { () async throws -> Rendered in
        let reply = try await page.render(source: request.code, theme: request.theme)
        guard case .diagram(let layout) = reply else {
          if case .error(let message) = reply { return .syntax(message) }
          throw MermaidPageError(reason: "unexpected reply")
        }
        let size = MermaidRaster.fit(
          CGSize(width: layout.width, height: layout.height), within: request.effectiveWidth,
          maximumAspectRatio: self.configuration.maximumAspectRatio)
        guard !state.isFinished else { throw MermaidTimeout() }
        job.sizeReady(size)
        let pixels = MermaidRaster.pixelSize(
          size,
          scale: MermaidRaster.rasterScale(
            for: size, scale: request.effectiveScale, maximumPixels: self.configuration.maximumPixels))
        let display = CGSize(
          width: CGFloat(pixels.width) / layout.pixelRatio, height: CGFloat(pixels.height) / layout.pixelRatio)
        let snapshot = try await page.snapshot(displaySize: display)
        return .snapshot(snapshot, size: size, pixels: pixels)
      }
      switch rendered {
      case .syntax(let message):
        return .failed(.syntax(message))
      case .snapshot(let snapshot, let size, let pixels):
        let background = request.theme.background
        let image = await MermaidRaster.offMain {
          OptionalImage(image: MermaidRaster.normalize(snapshot.image, pixels: pixels, background: background))
        }
        guard let image = image.image else { return .failed(.unavailable("could not draw the diagram")) }
        return .rendered(MermaidDiagram(size: size, image: image, failure: nil))
      }
    } catch is MermaidTimeout {
      shutDown()
      return .failed(.timedOut)
    } catch {
      shutDown()
      return .failed(.unavailable((error as? MermaidPageError)?.reason ?? error.localizedDescription))
    }
  }

  private func failQueuedJobs(_ reason: String) {
    let queued = jobs
    jobs = []
    for job in queued {
      if job.isWanted() {
        job.finished(.failed(.unavailable(reason)))
      } else {
        job.abandoned()
      }
    }
  }

  private func loadedPage() async throws -> MermaidPage {
    if let page, page.isUsable { return page }
    shutDown()
    guard let pageURL else { throw MermaidLoadFailure(reason: "mermaid resources not found") }
    if let startNotBefore, Date() < startNotBefore {
      throw MermaidLoadFailure(reason: "waiting before restarting after a failed start")
    }
    let fresh = MermaidPage(pageURL: pageURL)
    page = fresh
    startCount += 1
    do {
      try await withDeadline(configuration.loadTimeout) { try await fresh.load() }
      startNotBefore = nil
      return fresh
    } catch {
      shutDown()
      startNotBefore = Date().addingTimeInterval(configuration.failureBackoff)
      if error is MermaidTimeout { throw MermaidLoadFailure(reason: "the mermaid page did not load in time") }
      throw MermaidLoadFailure(reason: (error as? MermaidPageError)?.reason ?? error.localizedDescription)
    }
  }

  private func withDeadline<T: Sendable>(
    _ seconds: TimeInterval, _ operation: @escaping @MainActor () async throws -> T
  ) async throws -> T {
    let gate = ResumeGate<T>()
    return try await withCheckedThrowingContinuation { continuation in
      gate.continuation = continuation
      Task { @MainActor in
        do {
          gate.resume(.success(try await operation()))
        } catch {
          gate.resume(.failure(error))
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        MainActor.assumeIsolated { gate.resume(.failure(MermaidTimeout())) }
      }
    }
  }
}

enum MermaidRaster {
  struct PixelSize: Equatable, Sendable {
    var width: Int
    var height: Int
  }

  static func fit(_ intrinsic: CGSize, within width: CGFloat, maximumAspectRatio: CGFloat) -> CGSize {
    guard intrinsic.width > 0, intrinsic.height > 0 else { return intrinsic }
    let maximumHeight = width * maximumAspectRatio
    let factor = min(1, width / intrinsic.width, maximumHeight / intrinsic.height)
    return CGSize(width: intrinsic.width * factor, height: intrinsic.height * factor)
  }

  static func rasterScale(for size: CGSize, scale: CGFloat, maximumPixels: Int) -> CGFloat {
    let pixels = size.width * size.height * scale * scale
    guard pixels > CGFloat(maximumPixels), pixels > 0 else { return scale }
    return scale * (CGFloat(maximumPixels) / pixels).squareRoot()
  }

  static func pixelSize(_ size: CGSize, scale: CGFloat) -> PixelSize {
    PixelSize(
      width: max(Int((size.width * scale).rounded(.down)), 1), height: max(Int((size.height * scale).rounded(.down)), 1)
    )
  }

  static func normalize(_ image: CGImage, pixels: PixelSize, background: RGB) -> CGImage? {
    guard let context = MermaidErrorImage.makeContext(width: pixels.width, height: pixels.height) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
    context.setFillColor(MermaidErrorImage.cgColor(background))
    context.fill(rect)
    context.interpolationQuality = .high
    context.draw(image, in: rect)
    return context.makeImage()
  }

  static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
  }
}

struct OptionalImage: @unchecked Sendable {
  var image: CGImage?
}

@MainActor
private final class JobState {
  var isFinished = false
}

@MainActor
private final class ResumeGate<T: Sendable> {
  var continuation: CheckedContinuation<T, Error>?

  func resume(_ result: Result<T, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(with: result)
  }
}
