import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MDViewerCore

public enum ImageLocation: Hashable, Sendable {
  case local(URL)
  case remote(URL)

  public init?(source: String, relativeTo document: URL?) {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("//") {
      guard let url = URL(string: "https:" + trimmed), url.host != nil else { return nil }
      self = .remote(url)
      return
    }
    if let scheme = Self.scheme(of: trimmed) {
      guard let url = URL(string: trimmed) else { return nil }
      if scheme == "https", url.host?.isEmpty == false {
        self = .remote(url)
      } else if scheme == "file", url.isFileURL {
        self = .local(url.standardizedFileURL)
      } else {
        return nil
      }
      return
    }
    let withoutFragment = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
    let path = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
    guard let decoded = String(path).removingPercentEncoding, !decoded.isEmpty else { return nil }
    let directory = document?.deletingLastPathComponent().path ?? FileManager.default.currentDirectoryPath
    let absolute = decoded.hasPrefix("/") ? decoded : directory + "/" + decoded
    self = .local(URL(fileURLWithPath: (absolute as NSString).standardizingPath))
  }

  private static func scheme(of reference: String) -> String? {
    guard let colon = reference.firstIndex(of: ":") else { return nil }
    let candidate = reference[..<colon]
    guard let first = candidate.first, first.isASCII, first.isLetter,
      candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
    else { return nil }
    return candidate.lowercased()
  }
}

public struct LoadedImage: @unchecked Sendable {
  public let image: CGImage
  public let size: CGSize

  public init(image: CGImage, size: CGSize) {
    self.image = image
    self.size = size
  }
}

public final class ImageStore: @unchecked Sendable {
  public static let maximumDisplayDimension = 4096

  public struct Limits: Sendable {
    public var maximumBytes: Int
    public var maximumPixels: Int
    public var maximumDimension: Int
    public var cacheBytes: Int
    public var timeout: TimeInterval

    public init(
      maximumBytes: Int = 16 << 20,
      maximumPixels: Int = ImageStore.maximumDisplayDimension * ImageStore.maximumDisplayDimension,
      maximumDimension: Int = ImageStore.maximumDisplayDimension, cacheBytes: Int = 128 << 20,
      timeout: TimeInterval = 5
    ) {
      self.maximumBytes = maximumBytes
      self.maximumPixels = maximumPixels
      self.maximumDimension = maximumDimension
      self.cacheBytes = cacheBytes
      self.timeout = timeout
    }
  }

  struct FileStamp: Equatable {
    var modified: Date
    var size: Int

    init?(_ url: URL) {
      guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
        let modified = values.contentModificationDate, let size = values.fileSize
      else { return nil }
      self.modified = modified
      self.size = size
    }
  }

  private enum State {
    case loading(previous: LoadedImage?)
    case loaded(LoadedImage)
    case failed
  }

  private struct Entry {
    var state: State
    var stamp: FileStamp?
    var lastUse: UInt64 = 0
  }

  public let limits: Limits
  private let readLocal: @Sendable (URL) -> Data?
  private let fetchRemote: @Sendable (URL, @escaping @Sendable (Data?) -> Void) -> Void
  private let posterFrame: @Sendable (URL) -> CGImage?
  private let lock = NSLock()
  private var entries: [ImageLocation: Entry] = [:]
  private var pinned: Set<ImageLocation> = []
  private var useCounter: UInt64 = 0
  private var displayDimension = ImageStore.maximumDisplayDimension
  private let decoding = DispatchQueue(label: "md-viewer.images.decode", qos: .userInitiated)
  private let posters = DispatchQueue(label: "md-viewer.images.posters", qos: .utility)

  public init(
    limits: Limits = Limits(), readLocal: (@Sendable (URL) -> Data?)? = nil,
    fetchRemote: (@Sendable (URL, @escaping @Sendable (Data?) -> Void) -> Void)? = nil,
    posterFrame: (@Sendable (URL) -> CGImage?)? = nil
  ) {
    self.limits = limits
    self.posterFrame =
      posterFrame ?? { url in
        isPosterCandidate(url) ? VideoPosterFrame.generate(for: url) : nil
      }
    let maximumBytes = limits.maximumBytes
    self.readLocal = readLocal ?? { ImageStore.readSafeLocal($0, maximumBytes: maximumBytes) }
    if let fetchRemote {
      self.fetchRemote = fetchRemote
    } else {
      let fetcher = RemoteImageFetcher(maximumBytes: maximumBytes, timeout: limits.timeout)
      self.fetchRemote = { fetcher.fetch($0, completion: $1) }
    }
  }

  public static func readSafeLocal(_ url: URL, maximumBytes: Int) -> Data? {
    guard isSafeLocalImage(url),
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumBytes
    else { return nil }
    return try? Data(contentsOf: url, options: .mappedIfSafe)
  }

  public var cachedBytes: Int {
    lock.withLock { entries.values.reduce(0) { $0 + Self.cost($1) } }
  }

  public func setDisplayWidth(_ pixels: Int) {
    let dimension = min(max(pixels * 2, 1), limits.maximumDimension)
    lock.withLock { displayDimension = dimension }
  }

  public func pin(_ sources: [String], relativeTo document: URL?) {
    let locations = Set(sources.compactMap { ImageLocation(source: $0, relativeTo: document) })
    lock.withLock {
      pinned = locations
      evict()
    }
  }

  public func forgetFailures() {
    lock.withLock {
      entries = entries.filter {
        if case .failed = $0.value.state { return false }
        return true
      }
    }
  }

  public func image(for source: String, relativeTo document: URL?) -> LoadedImage? {
    guard let location = ImageLocation(source: source, relativeTo: document) else { return nil }
    return lock.withLock {
      guard var entry = entries[location] else { return nil }
      useCounter += 1
      entry.lastUse = useCounter
      entries[location] = entry
      switch entry.state {
      case .loaded(let image): return image
      case .loading(let previous): return previous
      case .failed: return nil
      }
    }
  }

  public func sizeProvider(relativeTo document: URL?) -> @Sendable (String) -> CGSize? {
    { [weak self] in self?.image(for: $0, relativeTo: document)?.size }
  }

  public func imageProvider(relativeTo document: URL?) -> @Sendable (String) -> CGImage? {
    { [weak self] in self?.image(for: $0, relativeTo: document)?.image }
  }

  @discardableResult
  public func load(
    _ source: String, relativeTo document: URL?, queue: DispatchQueue = .main,
    completion: @escaping @Sendable (Bool) -> Void
  ) -> Bool {
    guard let location = ImageLocation(source: source, relativeTo: document),
      let stamp = begin(location)
    else { return false }
    let finish: @Sendable (Data?) -> Void = { [weak self] data in
      guard let self else { return }
      let dimension = lock.withLock { displayDimension }
      let image = data.flatMap { ImageStore.decode($0, limits: self.limits, dimension: dimension) }
      store(image, at: location, stamp: stamp)
      queue.async { completion(image != nil) }
    }
    switch location {
    case .local(let url):
      let readLocal = readLocal
      decoding.async { finish(readLocal(url)) }
    case .remote(let url):
      fetchRemote(url) { [decoding] data in decoding.async { finish(data) } }
    }
    return true
  }

  @discardableResult
  public func loadPoster(
    _ source: String, relativeTo document: URL?, queue: DispatchQueue = .main,
    completion: @escaping @Sendable (Bool) -> Void
  ) -> Bool {
    guard case .local(let url)? = ImageLocation(source: source, relativeTo: document),
      let stamp = begin(.local(url))
    else { return false }
    let posterFrame = posterFrame
    posters.async { [weak self] in
      let image = posterFrame(url).map { LoadedImage(image: $0, size: CGSize(width: $0.width, height: $0.height)) }
      self?.store(image, at: .local(url), stamp: stamp)
      queue.async { completion(image != nil) }
    }
    return true
  }

  private func begin(_ location: ImageLocation) -> FileStamp?? {
    var stamp: FileStamp?
    if case .local(let url) = location { stamp = FileStamp(url) }
    return lock.withLock {
      var previous: LoadedImage?
      if let entry = entries[location] {
        switch entry.state {
        case .loading: return nil
        case .failed: guard stamp != nil, entry.stamp != stamp else { return nil }
        case .loaded(let image):
          guard stamp != nil, entry.stamp != stamp else { return nil }
          previous = image
        }
      }
      entries[location] = Entry(state: .loading(previous: previous), stamp: entries[location]?.stamp)
      return .some(stamp)
    }
  }

  private func store(_ image: LoadedImage?, at location: ImageLocation, stamp: FileStamp?) {
    lock.withLock {
      useCounter += 1
      entries[location] = Entry(state: image.map(State.loaded) ?? .failed, stamp: stamp, lastUse: useCounter)
      evict()
    }
  }

  private func evict() {
    var total = entries.values.reduce(0) { $0 + Self.cost($1) }
    guard total > limits.cacheBytes else { return }
    let candidates = entries.filter { !pinned.contains($0.key) && Self.cost($0.value) > 0 }
      .sorted { $0.value.lastUse < $1.value.lastUse }
    for (location, entry) in candidates where total > limits.cacheBytes {
      total -= Self.cost(entry)
      entries[location] = nil
    }
  }

  private static func cost(_ entry: Entry) -> Int {
    switch entry.state {
    case .loaded(let image), .loading(.some(let image)): image.image.bytesPerRow * image.image.height
    default: 0
    }
  }

  public static func decode(_ data: Data, limits: Limits, dimension: Int? = nil) -> LoadedImage? {
    guard data.count <= limits.maximumBytes,
      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width.multipliedReportingOverflow(by: height).partialValue <= limits.maximumPixels
    else { return nil }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    let size = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    let cap = min(dimension ?? limits.maximumDimension, limits.maximumDimension)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), max(cap, 1)),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return LoadedImage(image: image, size: size)
  }
}

public final class RemoteImageFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  public static let maximumRedirects = 5

  private struct Transfer {
    var data = Data()
    var rejected = false
    var redirects = 0
    var completion: @Sendable (Data?) -> Void
  }

  public let maximumBytes: Int
  private let lock = NSLock()
  private var transfers: [Int: Transfer] = [:]
  private var session: URLSession!

  public init(
    maximumBytes: Int, timeout: TimeInterval, configuration: URLSessionConfiguration = .ephemeral
  ) {
    self.maximumBytes = maximumBytes
    super.init()
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout * 2
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    let delegateQueue = OperationQueue()
    delegateQueue.maxConcurrentOperationCount = 1
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
  }

  public func fetch(_ url: URL, completion: @escaping @Sendable (Data?) -> Void) {
    guard url.scheme?.lowercased() == "https" else { return completion(nil) }
    var request = URLRequest(url: url)
    request.setValue("image/*", forHTTPHeaderField: "Accept")
    let task = session.dataTask(with: request)
    lock.withLock { transfers[task.taskIdentifier] = Transfer(completion: completion) }
    task.resume()
  }

  public func invalidate() {
    session.invalidateAndCancel()
  }

  public func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
    let tooLarge = response.expectedContentLength > Int64(maximumBytes)
    guard (200..<300).contains(status), !tooLarge else {
      reject(dataTask)
      return completionHandler(.cancel)
    }
    completionHandler(.allow)
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let allowed: Bool = lock.withLock {
      guard var transfer = transfers[task.taskIdentifier], request.url?.scheme?.lowercased() == "https",
        transfer.redirects < Self.maximumRedirects
      else {
        transfers[task.taskIdentifier]?.rejected = true
        return false
      }
      transfer.redirects += 1
      transfers[task.taskIdentifier] = transfer
      return true
    }
    if allowed {
      completionHandler(request)
    } else {
      completionHandler(nil)
      task.cancel()
    }
  }

  public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let overflow: Bool = lock.withLock {
      guard var transfer = transfers[dataTask.taskIdentifier], !transfer.rejected else { return false }
      transfer.data.append(data)
      if transfer.data.count > maximumBytes {
        transfer.rejected = true
        transfer.data = Data()
      }
      transfers[dataTask.taskIdentifier] = transfer
      return transfer.rejected
    }
    if overflow { dataTask.cancel() }
  }

  public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let transfer = lock.withLock({ transfers.removeValue(forKey: task.taskIdentifier) }) else { return }
    transfer.completion(error == nil && !transfer.rejected ? transfer.data : nil)
  }

  private func reject(_ task: URLSessionTask) {
    lock.withLock { transfers[task.taskIdentifier]?.rejected = true }
  }
}

public enum VideoPosterFrame {
  public static let timeout: TimeInterval = 3
  public static let maximumSize = CGSize(width: 1280, height: 720)

  public static func generate(for url: URL, timeout: TimeInterval = timeout) -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = maximumSize
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity
    let done = DispatchSemaphore(value: 0)
    let box = PosterBox()
    generator.generateCGImageAsynchronously(for: CMTime(seconds: 0.5, preferredTimescale: 600)) { image, _, _ in
      box.set(image)
      done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else {
      generator.cancelAllCGImageGeneration()
      return nil
    }
    return box.value
  }
}

private final class PosterBox: @unchecked Sendable {
  private let lock = NSLock()
  private var image: CGImage?
  var value: CGImage? { lock.withLock { image } }
  func set(_ image: CGImage?) { lock.withLock { self.image = image } }
}
