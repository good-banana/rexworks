import AppKit
import CoreGraphics
import Foundation
import MDViewerCore

struct MermaidJob: Sendable {
  var request: MermaidRequest
  var sizeReady: @Sendable (CGSize) -> Void
  var finished: @Sendable (MermaidDiagram) -> Void
}

struct MermaidTimeout: Error {}

@MainActor
final class MermaidEngine {
  let configuration: MermaidRenderer.Configuration
  let pageURL: URL?
  private var jobs: [MermaidJob] = []
  private var isBusy = false
  private var page: MermaidPage?
  private var idleShutdown: DispatchWorkItem?
  private(set) var startCount = 0

  nonisolated init(configuration: MermaidRenderer.Configuration, pageURL: URL?) {
    self.configuration = configuration
    self.pageURL = pageURL
  }

  var isRunning: Bool { page != nil }

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

  private func pump() {
    guard !isBusy else { return }
    guard !jobs.isEmpty else {
      scheduleIdleShutdown()
      return
    }
    isBusy = true
    let job = jobs.removeFirst()
    Task { @MainActor in
      let diagram = await self.run(job)
      job.finished(diagram)
      self.isBusy = false
      self.pump()
    }
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

  private enum Outcome: Sendable {
    case syntax(String)
    case rendered(SnapshotImage, size: CGSize, rasterScale: CGFloat)
  }

  private func run(_ job: MermaidJob) async -> MermaidDiagram {
    let request = job.request
    let state = JobState()
    defer { state.isFinished = true }
    do {
      let page = try await loadedPage()
      let outcome = try await withDeadline(configuration.diagramTimeout) { () async throws -> Outcome in
        let reply = try await page.render(source: request.code, theme: request.theme)
        guard case .diagram(let layout) = reply else {
          if case .error(let message) = reply { return .syntax(message) }
          throw MermaidPageError(reason: "unexpected reply")
        }
        let size = Self.fit(CGSize(width: layout.width, height: layout.height), within: request.effectiveWidth)
        guard !state.isFinished else { throw MermaidTimeout() }
        job.sizeReady(size)
        let rasterScale = Self.rasterScale(
          for: size, scale: request.effectiveScale, maximumPixels: self.configuration.maximumPixels)
        let display = CGSize(
          width: size.width * rasterScale / layout.pixelRatio, height: size.height * rasterScale / layout.pixelRatio)
        let snapshot = try await page.snapshot(displaySize: display)
        return .rendered(snapshot, size: size, rasterScale: rasterScale)
      }
      switch outcome {
      case .syntax(let message):
        return failure(.syntax(message), request)
      case .rendered(let snapshot, let size, let rasterScale):
        guard
          let image = Self.normalize(
            snapshot.image, size: size, scale: rasterScale, background: request.theme.background)
        else { return failure(.unavailable("could not draw the diagram"), request) }
        return MermaidDiagram(size: size, image: image, failure: nil)
      }
    } catch is MermaidTimeout {
      shutDown()
      return failure(.timedOut, request)
    } catch {
      shutDown()
      let reason = (error as? MermaidPageError)?.reason ?? error.localizedDescription
      return failure(.unavailable(reason), request)
    }
  }

  private func failure(_ failure: MermaidFailure, _ request: MermaidRequest) -> MermaidDiagram {
    if let diagram = MermaidErrorImage.make(
      failure, theme: request.theme, width: request.effectiveWidth, scale: request.effectiveScale)
    {
      return diagram
    }
    let blank = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    return MermaidDiagram(size: CGSize(width: 1, height: 1), image: blank!.makeImage()!, failure: failure)
  }

  private func loadedPage() async throws -> MermaidPage {
    if let page, page.isUsable { return page }
    page?.close()
    guard let pageURL else { throw MermaidPageError(reason: "mermaid resources not found") }
    let fresh = MermaidPage(pageURL: pageURL)
    page = fresh
    startCount += 1
    try await withDeadline(configuration.loadTimeout) { try await fresh.load() }
    return fresh
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

  static func fit(_ intrinsic: CGSize, within width: CGFloat) -> CGSize {
    guard intrinsic.width > width, intrinsic.width > 0 else { return intrinsic }
    return CGSize(width: width, height: intrinsic.height * width / intrinsic.width)
  }

  static func rasterScale(for size: CGSize, scale: CGFloat, maximumPixels: Int) -> CGFloat {
    let pixels = size.width * size.height * scale * scale
    guard pixels > CGFloat(maximumPixels), pixels > 0 else { return scale }
    return scale * (CGFloat(maximumPixels) / pixels).squareRoot()
  }

  static func normalize(_ image: CGImage, size: CGSize, scale: CGFloat, background: RGB) -> CGImage? {
    let width = max(Int((size.width * scale).rounded(.up)), 1)
    let height = max(Int((size.height * scale).rounded(.up)), 1)
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(MermaidErrorImage.cgColor(background))
    context.fill(rect)
    context.interpolationQuality = .high
    context.draw(image, in: rect)
    return context.makeImage()
  }
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
