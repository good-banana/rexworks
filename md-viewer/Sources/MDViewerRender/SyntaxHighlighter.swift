import CryptoKit
import Foundation
import JavaScriptCore
import MDViewerLayout

public struct HighlightResult: Hashable, Sendable {
  public enum Outcome: Hashable, Sendable {
    case highlighted(language: String)
    case belowRelevanceThreshold
    case unsupportedLanguage
    case tooLarge
    case failed
  }

  public var outcome: Outcome
  public var lines: [[TokenSpan]]

  public init(outcome: Outcome, lines: [[TokenSpan]] = []) {
    self.outcome = outcome
    self.lines = lines
  }

  public var language: String? {
    if case .highlighted(let language) = outcome { return language }
    return nil
  }

  public var isHighlighted: Bool { language != nil }

  public func tokens(line: Int) -> [TokenSpan] { line >= 0 && line < lines.count ? lines[line] : [] }
}

public final class SyntaxHighlighter: @unchecked Sendable {
  public struct Configuration: Sendable {
    public var maximumInputLength = 200_000
    public var autoDetectMinimumRelevance = 5
    public var autoDetectSampleLength = 8_000
    public var cacheLimit = 512

    public init() {}
  }

  public static let plainLanguages: Set<String> = ["text", "txt", "plain", "plaintext", "nohighlight", "none"]
  public static let bundleName = "md-viewer_MDViewerRender.bundle"

  public let configuration: Configuration
  private let scriptURL: URL?
  private let queue = DispatchQueue(label: "md-viewer.highlight", qos: .userInitiated)
  private let lock = NSLock()
  private var cache: [CacheKey: HighlightResult] = [:]
  private var cacheOrder: [CacheKey] = []
  private var waiting: [CacheKey: [(DispatchQueue, @Sendable (HighlightResult) -> Void)]] = [:]
  private var context: JSContext?
  private var function: JSValue?
  private var contextFailed = false

  private struct CacheKey: Hashable {
    var digest: SHA256.Digest
    var language: String?
  }

  public init(scriptURL: URL? = SyntaxHighlighter.locateScript(), configuration: Configuration = Configuration()) {
    self.scriptURL = scriptURL
    self.configuration = configuration
  }

  public static func locateScript() -> URL? {
    var directories = [
      Bundle.main.bundleURL, Bundle(for: SyntaxHighlighter.self).bundleURL.deletingLastPathComponent(),
    ]
    if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
      let directory = executable.deletingLastPathComponent()
      directories.append(directory)
      directories.append(directory.appendingPathComponent("../libexec").standardizedFileURL)
    }
    for directory in directories {
      let candidate = directory.appendingPathComponent(bundleName)
      let base = Bundle(url: candidate).flatMap(\.resourceURL) ?? candidate
      let script = base.appendingPathComponent("highlight.min.js")
      if FileManager.default.fileExists(atPath: script.path) { return script }
    }
    return nil
  }

  public static func normalizedLanguage(_ language: String?) -> String? {
    guard let trimmed = language?.trimmingCharacters(in: .whitespaces).lowercased(), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  public func cached(code: String, language: String?) -> HighlightResult? {
    let key = cacheKey(code: code, language: language)
    lock.lock()
    defer { lock.unlock() }
    return cache[key]
  }

  public func highlight(
    code: String, language: String?, queue callbackQueue: DispatchQueue = .main,
    completion: @escaping @Sendable (HighlightResult) -> Void
  ) {
    let language = Self.normalizedLanguage(language)
    let key = cacheKey(code: code, language: language)
    lock.lock()
    if let result = cache[key] {
      lock.unlock()
      callbackQueue.async { completion(result) }
      return
    }
    if waiting[key] != nil {
      waiting[key]?.append((callbackQueue, completion))
      lock.unlock()
      return
    }
    waiting[key] = [(callbackQueue, completion)]
    lock.unlock()
    queue.async { [self] in
      let result = compute(code: code, language: language)
      lock.lock()
      store(result, for: key)
      let callbacks = waiting.removeValue(forKey: key) ?? []
      lock.unlock()
      for (callbackQueue, callback) in callbacks { callbackQueue.async { callback(result) } }
    }
  }

  @discardableResult
  public func highlight(
    _ prepared: PreparedDocument, queue callbackQueue: DispatchQueue = .main,
    completion: @escaping @Sendable (BlockID, HighlightResult) -> Void
  ) -> [BlockID: HighlightResult] {
    var ready: [BlockID: HighlightResult] = [:]
    for (id, block) in prepared.codeBlocks where !block.isDiagram {
      if let result = cached(code: block.code, language: block.language) {
        ready[id] = result
      } else {
        highlight(code: block.code, language: block.language, queue: callbackQueue) { completion(id, $0) }
      }
    }
    return ready
  }

  private func cacheKey(code: String, language: String?) -> CacheKey {
    CacheKey(digest: SHA256.hash(data: Data(code.utf8)), language: Self.normalizedLanguage(language))
  }

  private func store(_ result: HighlightResult, for key: CacheKey) {
    if cache.updateValue(result, forKey: key) == nil { cacheOrder.append(key) }
    while cacheOrder.count > max(configuration.cacheLimit, 1) {
      cache.removeValue(forKey: cacheOrder.removeFirst())
    }
  }

  private func compute(code: String, language: String?) -> HighlightResult {
    let length = code.utf16.count
    if length > configuration.maximumInputLength { return HighlightResult(outcome: .tooLarge) }
    if let language, Self.plainLanguages.contains(language) { return HighlightResult(outcome: .unsupportedLanguage) }
    if length == 0 { return HighlightResult(outcome: .failed) }
    guard let function = loadedFunction() else { return HighlightResult(outcome: .failed) }
    let arguments: [Any] = [
      code, language ?? NSNull(), configuration.autoDetectMinimumRelevance, configuration.autoDetectSampleLength,
    ]
    guard let value = function.call(withArguments: arguments), context?.exception == nil, value.isObject,
      let object = value.toDictionary()
    else {
      context?.exception = nil
      return HighlightResult(outcome: .failed)
    }
    switch object["status"] as? String {
    case "unsupported": return HighlightResult(outcome: .unsupportedLanguage)
    case "belowThreshold": return HighlightResult(outcome: .belowRelevanceThreshold)
    case "ok": break
    default: return HighlightResult(outcome: .failed)
    }
    let detected = object["language"] as? String ?? language ?? ""
    let spans = object["spans"] as? [[Any]] ?? []
    return HighlightResult(outcome: .highlighted(language: detected), lines: Self.lines(spans, code: code))
  }

  static func lines(_ spans: [[Any]], code: String) -> [[TokenSpan]] {
    var lineStarts: [Int] = [0]
    var offset = 0
    for unit in code.utf16 {
      offset += 1
      if unit == 0x0A { lineStarts.append(offset) }
    }
    var lines = [[TokenSpan]](repeating: [], count: lineStarts.count)
    var line = 0
    for span in spans {
      guard span.count == 3, let start = (span[0] as? NSNumber)?.intValue,
        let length = (span[1] as? NSNumber)?.intValue, let chain = span[2] as? String, length > 0,
        let token = SyntaxScopes.token(forScopeChain: chain.components(separatedBy: "|"))
      else { continue }
      let end = start + length
      while line + 1 < lineStarts.count, lineStarts[line + 1] <= start { line += 1 }
      var current = line
      var cursor = start
      while cursor < end, current < lineStarts.count {
        let lineStart = lineStarts[current]
        let lineEnd = current + 1 < lineStarts.count ? lineStarts[current + 1] - 1 : offset
        let pieceEnd = min(end, lineEnd)
        if pieceEnd > cursor {
          let range = (cursor - lineStart)..<(pieceEnd - lineStart)
          if let last = lines[current].last, last.token == token, last.range.upperBound == range.lowerBound {
            lines[current][lines[current].count - 1].range = last.range.lowerBound..<range.upperBound
          } else {
            lines[current].append(TokenSpan(range: range, token: token))
          }
        }
        current += 1
        cursor = current < lineStarts.count ? lineStarts[current] : end
      }
    }
    return lines
  }

  private func loadedFunction() -> JSValue? {
    if let function { return function }
    guard !contextFailed else { return nil }
    contextFailed = true
    guard let scriptURL, let script = try? String(contentsOf: scriptURL, encoding: .utf8),
      let context = JSContext()
    else { return nil }
    context.evaluateScript(script)
    context.evaluateScript(Self.glue)
    guard context.exception == nil, let function = context.objectForKeyedSubscript("__mdvHighlight"),
      !function.isUndefined
    else { return nil }
    self.context = context
    self.function = function
    contextFailed = false
    return function
  }

  private static let glue = """
    function __mdvHighlight(code, language, minimumRelevance, sampleLength) {
      var result;
      if (language) {
        if (!hljs.getLanguage(language)) return { status: "unsupported" };
        result = hljs.highlight(code, { language: language, ignoreIllegals: true });
      } else {
        var probe = hljs.highlightAuto(code.length > sampleLength ? code.slice(0, sampleLength) : code);
        if (!probe.language || probe.relevance < minimumRelevance) return { status: "belowThreshold" };
        result = code.length > sampleLength
          ? hljs.highlight(code, { language: probe.language, ignoreIllegals: true }) : probe;
      }
      var entities = { "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\\"", "&#x27;": "'", "&#39;": "'" };
      var pattern = /<span class="([^"]*)">|<\\/span>|([^<]+)/g;
      var stack = [], spans = [], offset = 0, match;
      while ((match = pattern.exec(result.value)) !== null) {
        if (match[1] !== undefined) {
          stack.push(match[1]);
        } else if (match[2] !== undefined) {
          var text = match[2].replace(/&(amp|lt|gt|quot|#x27|#39);/g, function (entity) { return entities[entity]; });
          if (stack.length > 0) spans.push([offset, text.length, stack.join("|")]);
          offset += text.length;
        } else {
          stack.pop();
        }
      }
      return { status: "ok", language: result.language || language, spans: spans };
    }
    """
}
