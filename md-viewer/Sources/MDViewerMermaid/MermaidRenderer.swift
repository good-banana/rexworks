import CoreGraphics
import Foundation
import os

public final class MermaidRenderer: @unchecked Sendable {
  public struct Configuration: Sendable {
    public var idleTimeout: TimeInterval
    public var diagramTimeout: TimeInterval
    public var retryTimeout: TimeInterval
    public var timeoutRetryDelay: TimeInterval
    public var loadTimeout: TimeInterval
    public var failureBackoff: TimeInterval
    public var cacheByteLimit: Int
    public var failureCacheByteLimit: Int
    public var maximumPixels: Int
    public var maximumAspectRatio: CGFloat

    public init(
      idleTimeout: TimeInterval = 30, diagramTimeout: TimeInterval = 5, retryTimeout: TimeInterval = 15,
      timeoutRetryDelay: TimeInterval = 10, loadTimeout: TimeInterval = 15, failureBackoff: TimeInterval = 30,
      cacheByteLimit: Int = 256 << 20, failureCacheByteLimit: Int = 32 << 20, maximumPixels: Int = 8 << 20,
      maximumAspectRatio: CGFloat = 4
    ) {
      self.idleTimeout = idleTimeout
      self.diagramTimeout = diagramTimeout
      self.retryTimeout = retryTimeout
      self.timeoutRetryDelay = timeoutRetryDelay
      self.loadTimeout = loadTimeout
      self.failureBackoff = failureBackoff
      self.cacheByteLimit = cacheByteLimit
      self.failureCacheByteLimit = failureCacheByteLimit
      self.maximumPixels = maximumPixels
      self.maximumAspectRatio = maximumAspectRatio
    }
  }

  public static let bundleName = "md-viewer_MDViewerMermaid.bundle"

  private struct Waiter {
    var queue: DispatchQueue
    var sizeReady: (@Sendable (CGSize) -> Void)?
    var completion: @Sendable (MermaidDiagram) -> Void
    var sentSize: CGSize?
  }

  private struct Pending {
    var waiters: [Waiter]
    var size: CGSize?
  }

  private struct TimeoutRecord {
    var isPermanent: Bool
    var retryAfter: Date
  }

  public let configuration: Configuration
  let engine: MermaidEngine
  private let lock = NSLock()
  private let workQueue = DispatchQueue(label: "md-viewer.mermaid.work", qos: .userInitiated)
  private var cache: MermaidImageCache
  private var failures: MermaidImageCache
  private var pending: [MermaidCacheKey: Pending] = [:]
  private var timeouts: [MermaidSourceKey: TimeoutRecord] = [:]
  private var wanted: Set<MermaidCacheKey>?
  private var currentOrder: [MermaidCacheKey: Int] = [:]
  private var nextSequence = 0
  private var reportedPinnedOverflow = false
  private static let log = Logger(subsystem: "md-viewer", category: "mermaid")

  public init(configuration: Configuration = Configuration(), pageURL: URL? = MermaidRenderer.locatePage()) {
    self.configuration = configuration
    cache = MermaidImageCache(byteLimit: configuration.cacheByteLimit)
    failures = MermaidImageCache(byteLimit: configuration.failureCacheByteLimit)
    engine = MermaidEngine(configuration: configuration, pageURL: pageURL)
  }

  public static func locatePage() -> URL? {
    var directories = [
      Bundle.main.bundleURL, Bundle(for: MermaidRenderer.self).bundleURL.deletingLastPathComponent(),
    ]
    if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
      let directory = executable.deletingLastPathComponent()
      directories.append(directory)
      directories.append(directory.appendingPathComponent("../libexec").standardizedFileURL)
    }
    return locatePage(candidates: directories.map { $0.appendingPathComponent(bundleName) })
  }

  static func locatePage(candidates: [URL]) -> URL? {
    for candidate in candidates {
      let base = Bundle(url: candidate).flatMap(\.resourceURL) ?? candidate
      let page = base.appendingPathComponent("mermaid/mermaid.html")
      let script = base.appendingPathComponent("mermaid/mermaid.min.js")
      if FileManager.default.fileExists(atPath: page.path), FileManager.default.fileExists(atPath: script.path) {
        return page
      }
    }
    return nil
  }

  public func cached(_ request: MermaidRequest) -> MermaidDiagram? {
    let key = request.key
    return lock.withLock { lookup(key) }
  }

  public func sizeProvider(theme: MermaidTheme, width: CGFloat, scale: CGFloat) -> @Sendable (String) -> CGSize? {
    { [weak self] code in
      self?.cached(MermaidRequest(code: code, theme: theme, width: width, scale: scale))?.size
    }
  }

  public func imageProvider(theme: MermaidTheme, width: CGFloat, scale: CGFloat) -> @Sendable (String) -> CGImage? {
    { [weak self] code in
      self?.cached(MermaidRequest(code: code, theme: theme, width: width, scale: scale))?.image
    }
  }

  /// Declares the diagrams the viewer still needs, most important first. Their cache entries are pinned and
  /// queued requests run in this order. Queued requests for any other key complete with `.cancelled`; request
  /// such a diagram again (for example on a provider miss) if it is needed later.
  public func setCurrentDiagrams(_ requests: [MermaidRequest]) {
    let keys = requests.map(\.key)
    lock.withLock {
      wanted = Set(keys)
      currentOrder = [:]
      for (index, key) in keys.enumerated() where currentOrder[key] == nil {
        currentOrder[key] = index
      }
      cache.pinned = Set(keys)
      failures.pinned = Set(keys)
      checkPinnedBudget()
    }
  }

  /// Renders a diagram, coalescing identical requests. `sizeReady` runs before `completion`, both on `queue`.
  /// A request dropped by `setCurrentDiagrams` completes with `.cancelled`, which is never cached.
  public func render(
    _ request: MermaidRequest, queue: DispatchQueue = .main, sizeReady: (@Sendable (CGSize) -> Void)? = nil,
    completion: @escaping @Sendable (MermaidDiagram) -> Void
  ) {
    let key = request.key
    var waiter = Waiter(
      queue: DispatchQueue(label: "md-viewer.mermaid.callback", target: queue), sizeReady: sizeReady,
      completion: completion)
    lock.lock()
    wanted?.insert(key)
    if let diagram = lookup(key) {
      deliver(diagram, to: [waiter])
      lock.unlock()
      return
    }
    if var entry = pending[key] {
      if let size = entry.size {
        send(size, to: &waiter)
      }
      entry.waiters.append(waiter)
      pending[key] = entry
      lock.unlock()
      return
    }
    pending[key] = Pending(waiters: [waiter])
    let record = timeouts[key.source]
    if let record, record.isPermanent || Date() < record.retryAfter {
      lock.unlock()
      resolve(.timedOut, request: request, key: key, isRetry: false)
      return
    }
    nextSequence += 1
    let sequence = nextSequence
    lock.unlock()

    let isRetry = record != nil
    let job = MermaidJob(
      request: request, sequence: sequence,
      deadline: isRetry ? configuration.retryTimeout : configuration.diagramTimeout,
      dropIfUnwanted: { [self] in dropIfUnwanted(key) },
      rank: { [self] in lock.withLock { currentOrder[key] } },
      sizeReady: { [self] size in reportSize(size, for: key) },
      finished: { [self] outcome in finish(outcome, request: request, key: key, isRetry: isRetry) })
    let engine = engine
    DispatchQueue.main.async {
      MainActor.assumeIsolated { engine.enqueue(job) }
    }
  }

  public func shutDown() {
    let engine = engine
    DispatchQueue.main.async {
      MainActor.assumeIsolated { engine.shutDown() }
    }
  }

  func isCachedInMainStore(_ request: MermaidRequest) -> Bool {
    let key = request.key
    return lock.withLock { cache.value(for: key) != nil }
  }

  private func lookup(_ key: MermaidCacheKey) -> MermaidDiagram? {
    cache.value(for: key) ?? failures.value(for: key)
  }

  private func dropIfUnwanted(_ key: MermaidCacheKey) -> Bool {
    lock.withLock {
      guard let wanted, !wanted.contains(key) else { return false }
      complete(key, with: .cancelled)
      return true
    }
  }

  private func checkPinnedBudget() {
    guard !reportedPinnedOverflow, cache.pinnedBytes > cache.byteLimit else { return }
    reportedPinnedOverflow = true
    Self.log.notice(
      "pinned Mermaid diagrams use \(self.cache.pinnedBytes) bytes, over the \(self.cache.byteLimit) byte cache limit")
  }

  private func reportSize(_ size: CGSize, for key: MermaidCacheKey) {
    lock.withLock {
      guard var entry = pending[key] else { return }
      entry.size = size
      for index in entry.waiters.indices {
        send(size, to: &entry.waiters[index])
      }
      pending[key] = entry
    }
  }

  private func finish(_ outcome: MermaidOutcome, request: MermaidRequest, key: MermaidCacheKey, isRetry: Bool) {
    switch outcome {
    case .rendered(let diagram):
      lock.withLock {
        timeouts[key.source] = nil
        cache.insert(diagram, for: key)
        checkPinnedBudget()
        complete(key, with: diagram)
      }
    case .failed(let failure):
      resolve(failure, request: request, key: key, isRetry: isRetry)
    }
  }

  private func resolve(_ failure: MermaidFailure, request: MermaidRequest, key: MermaidCacheKey, isRetry: Bool) {
    if failure == .cancelled {
      return lock.withLock { complete(key, with: .cancelled) }
    }
    let configuration = configuration
    workQueue.async { [self] in
      let diagram = MermaidErrorImage.make(
        failure, theme: request.theme, width: request.effectiveWidth, scale: request.effectiveScale)
      lock.withLock {
        let now = Date()
        switch failure {
        case .syntax:
          cache.insert(diagram, for: key)
        case .cancelled:
          break
        case .unavailable:
          failures.insert(diagram, for: key, expiry: now.addingTimeInterval(configuration.failureBackoff))
        case .timedOut:
          var record =
            timeouts[key.source]
            ?? TimeoutRecord(isPermanent: false, retryAfter: now.addingTimeInterval(configuration.timeoutRetryDelay))
          if isRetry { record.isPermanent = true }
          timeouts[key.source] = record
          failures.insert(diagram, for: key, expiry: record.isPermanent ? nil : record.retryAfter)
        }
        complete(key, with: diagram)
      }
    }
  }

  private func complete(_ key: MermaidCacheKey, with diagram: MermaidDiagram) {
    guard let entry = pending.removeValue(forKey: key) else { return }
    deliver(diagram, to: entry.waiters)
  }

  private func send(_ size: CGSize, to waiter: inout Waiter) {
    guard waiter.sentSize != size else { return }
    waiter.sentSize = size
    if let sizeReady = waiter.sizeReady {
      waiter.queue.async { sizeReady(size) }
    }
  }

  private func deliver(_ diagram: MermaidDiagram, to waiters: [Waiter]) {
    for var waiter in waiters {
      if diagram.failure != .cancelled {
        send(diagram.size, to: &waiter)
      }
      let completion = waiter.completion
      waiter.queue.async { completion(diagram) }
    }
  }
}
