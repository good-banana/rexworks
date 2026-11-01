import CoreGraphics
import Foundation

public final class MermaidRenderer: @unchecked Sendable {
  public struct Configuration: Sendable {
    public var idleTimeout: TimeInterval
    public var diagramTimeout: TimeInterval
    public var loadTimeout: TimeInterval
    public var cacheByteLimit: Int
    public var maximumPixels: Int

    public init(
      idleTimeout: TimeInterval = 30, diagramTimeout: TimeInterval = 5, loadTimeout: TimeInterval = 15,
      cacheByteLimit: Int = 64 << 20, maximumPixels: Int = 16 << 20
    ) {
      self.idleTimeout = idleTimeout
      self.diagramTimeout = diagramTimeout
      self.loadTimeout = loadTimeout
      self.cacheByteLimit = cacheByteLimit
      self.maximumPixels = maximumPixels
    }
  }

  public static let bundleName = "md-viewer_MDViewerMermaid.bundle"

  private struct Waiter {
    var queue: DispatchQueue
    var sizeReady: (@Sendable (CGSize) -> Void)?
    var completion: @Sendable (MermaidDiagram) -> Void
  }

  private struct Pending {
    var waiters: [Waiter]
    var size: CGSize?
  }

  public let configuration: Configuration
  let engine: MermaidEngine
  private let lock = NSLock()
  private var cache: MermaidImageCache
  private var pending: [MermaidCacheKey: Pending] = [:]

  public init(configuration: Configuration = Configuration(), pageURL: URL? = MermaidRenderer.locatePage()) {
    self.configuration = configuration
    cache = MermaidImageCache(byteLimit: configuration.cacheByteLimit)
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
    lock.lock()
    defer { lock.unlock() }
    return cache.value(for: key)
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

  public func render(
    _ request: MermaidRequest, queue: DispatchQueue = .main, sizeReady: (@Sendable (CGSize) -> Void)? = nil,
    completion: @escaping @Sendable (MermaidDiagram) -> Void
  ) {
    let key = request.key
    let waiter = Waiter(queue: queue, sizeReady: sizeReady, completion: completion)
    lock.lock()
    if let diagram = cache.value(for: key) {
      lock.unlock()
      deliver(diagram, to: [waiter], sizeAlreadySent: false)
      return
    }
    if var entry = pending[key] {
      entry.waiters.append(waiter)
      pending[key] = entry
      let size = entry.size
      lock.unlock()
      if let size, let sizeReady { queue.async { sizeReady(size) } }
      return
    }
    pending[key] = Pending(waiters: [waiter], size: nil)
    lock.unlock()

    let job = MermaidJob(
      request: request,
      sizeReady: { [self] size in reportSize(size, for: key) },
      finished: { [self] diagram in finish(diagram, for: key) })
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

  private func reportSize(_ size: CGSize, for key: MermaidCacheKey) {
    lock.lock()
    guard var entry = pending[key] else {
      lock.unlock()
      return
    }
    entry.size = size
    pending[key] = entry
    let waiters = entry.waiters
    lock.unlock()
    for waiter in waiters {
      if let sizeReady = waiter.sizeReady { waiter.queue.async { sizeReady(size) } }
    }
  }

  private func finish(_ diagram: MermaidDiagram, for key: MermaidCacheKey) {
    lock.lock()
    let entry = pending.removeValue(forKey: key)
    if diagram.failure?.isCacheable ?? true {
      cache.insert(diagram, for: key)
    }
    lock.unlock()
    guard let entry else { return }
    deliver(diagram, to: entry.waiters, sizeAlreadySent: entry.size == diagram.size)
  }

  private func deliver(_ diagram: MermaidDiagram, to waiters: [Waiter], sizeAlreadySent: Bool) {
    for waiter in waiters {
      waiter.queue.async {
        if !sizeAlreadySent { waiter.sizeReady?(diagram.size) }
        waiter.completion(diagram)
      }
    }
  }
}
