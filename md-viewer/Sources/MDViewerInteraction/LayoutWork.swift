import CoreGraphics
import Foundation
import MDViewerLayout

public struct LayoutRequest: Equatable, @unchecked Sendable {
  public var generation: Int
  public var source: String?
  public var reuse: PreparedDocument?
  public var typography: Typography
  public var width: CGFloat
  public var expandedDetails: Set<BlockID>?
  public var scrollOffsets: [BlockID: CGFloat]

  public var preparesAgain: Bool { source != nil || reuse == nil }

  public static func == (lhs: LayoutRequest, rhs: LayoutRequest) -> Bool {
    lhs.generation == rhs.generation && lhs.source == rhs.source && lhs.reuse === rhs.reuse
      && lhs.typography == rhs.typography && lhs.width == rhs.width && lhs.expandedDetails == rhs.expandedDetails
      && lhs.scrollOffsets == rhs.scrollOffsets
  }

  public func perform(_ providers: LayoutProviders = LayoutProviders()) -> PageLayout {
    let prepared: PreparedDocument
    if let source {
      prepared = PreparedDocument(markdown: source, typography: typography)
    } else if let reuse {
      prepared = reuse
    } else {
      prepared = PreparedDocument(markdown: "", typography: typography)
    }
    return prepared.layout(
      LayoutInput(
        width: width, expandedDetails: expandedDetails ?? prepared.initiallyExpandedDetails,
        prefersDark: providers.prefersDark, scrollOffsets: scrollOffsets, imageSize: providers.imageSize,
        diagramSize: providers.diagramSize))
  }
}

public struct LayoutProviders: Sendable {
  public var prefersDark: Bool
  public var imageSize: @Sendable (String) -> CGSize?
  public var diagramSize: @Sendable (String) -> CGSize?

  public init(
    prefersDark: Bool = false, imageSize: @escaping @Sendable (String) -> CGSize? = { _ in nil },
    diagramSize: @escaping @Sendable (String) -> CGSize? = { _ in nil }
  ) {
    self.prefersDark = prefersDark
    self.imageSize = imageSize
    self.diagramSize = diagramSize
  }
}

public final class LayoutWorker: @unchecked Sendable {
  public static var defaultStackSize: Int {
    #if DEBUG
      4 * 1024 * 1024
    #else
      1024 * 1024
    #endif
  }

  private final class JobQueue: @unchecked Sendable {
    let condition = NSCondition()
    var jobs: [() -> Void] = []
    var stopped = false

    func run() {
      while true {
        condition.lock()
        while jobs.isEmpty && !stopped { condition.wait() }
        if jobs.isEmpty {
          condition.unlock()
          return
        }
        let job = jobs.removeFirst()
        condition.unlock()
        job()
      }
    }

    func enqueue(_ job: @escaping () -> Void) -> Bool {
      condition.lock()
      defer { condition.unlock() }
      guard !stopped else { return false }
      jobs.append(job)
      condition.signal()
      return true
    }

    func stop() {
      condition.lock()
      stopped = true
      condition.broadcast()
      condition.unlock()
    }
  }

  public let stackSize: Int
  private let queue = JobQueue()

  public init(stackSize: Int = LayoutWorker.defaultStackSize, name: String = "md-viewer.layout") {
    self.stackSize = max(stackSize, 1024 * 1024)
    let thread = Thread { [queue] in queue.run() }
    thread.stackSize = self.stackSize
    thread.name = name
    thread.start()
  }

  deinit { queue.stop() }

  public func submit(_ job: @escaping @Sendable () -> Void) {
    _ = queue.enqueue(job)
  }

  public func perform<T>(_ job: @escaping () -> T) -> T {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    let accepted = queue.enqueue {
      result = job()
      done.signal()
    }
    guard accepted else { return job() }
    done.wait()
    return result!
  }

  public func layout(
    _ request: LayoutRequest, providers: LayoutProviders, completion: @escaping @Sendable (PageLayout) -> Void
  ) {
    submit { completion(request.perform(providers)) }
  }

  public func stop() { queue.stop() }
}
