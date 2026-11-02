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
      if scheme == "http" || scheme == "https", url.host?.isEmpty == false {
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
  public struct Limits: Sendable {
    public var maximumBytes: Int
    public var maximumPixels: Int
    public var maximumDimension: Int
    public var timeout: TimeInterval

    public init(
      maximumBytes: Int = 16 << 20, maximumPixels: Int = 64 << 20, maximumDimension: Int = 8192,
      timeout: TimeInterval = 5
    ) {
      self.maximumBytes = maximumBytes
      self.maximumPixels = maximumPixels
      self.maximumDimension = maximumDimension
      self.timeout = timeout
    }
  }

  private enum Entry {
    case loading
    case loaded(LoadedImage)
    case failed
  }

  public let limits: Limits
  private let readLocal: @Sendable (URL) -> Data?
  private let fetchRemote: @Sendable (URL, @escaping @Sendable (Data?) -> Void) -> Void
  private let lock = NSLock()
  private var entries: [ImageLocation: Entry] = [:]
  private let work = DispatchQueue(label: "md-viewer.images", qos: .userInitiated, attributes: .concurrent)

  public init(
    limits: Limits = Limits(), readLocal: (@Sendable (URL) -> Data?)? = nil,
    fetchRemote: (@Sendable (URL, @escaping @Sendable (Data?) -> Void) -> Void)? = nil
  ) {
    self.limits = limits
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

  public func image(for source: String, relativeTo document: URL?) -> LoadedImage? {
    guard let location = ImageLocation(source: source, relativeTo: document) else { return nil }
    return lock.withLock {
      if case .loaded(let image) = entries[location] { return image }
      return nil
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
    guard let location = ImageLocation(source: source, relativeTo: document) else { return false }
    let started: Bool = lock.withLock {
      guard entries[location] == nil else { return false }
      entries[location] = .loading
      return true
    }
    guard started else { return false }
    let finish: @Sendable (Data?) -> Void = { [weak self] data in
      guard let self else { return }
      let image = data.flatMap { ImageStore.decode($0, limits: self.limits) }
      self.lock.withLock { self.entries[location] = image.map(Entry.loaded) ?? .failed }
      queue.async { completion(image != nil) }
    }
    switch location {
    case .local(let url):
      let readLocal = readLocal
      work.async { finish(readLocal(url)) }
    case .remote(let url):
      fetchRemote(url) { [work] data in work.async { finish(data) } }
    }
    return true
  }

  public static func decode(_ data: Data, limits: Limits) -> LoadedImage? {
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
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), limits.maximumDimension),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return LoadedImage(image: image, size: size)
  }
}

public final class RemoteImageFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private struct Transfer {
    var data = Data()
    var rejected = false
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
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return completion(nil) }
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
