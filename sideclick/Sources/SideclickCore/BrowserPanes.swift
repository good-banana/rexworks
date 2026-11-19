import Foundation

public struct BrowserInstance: Equatable, Sendable {
  public var key: String
  public var tty: String

  public init(key: String, tty: String) {
    self.key = key
    self.tty = tty
  }
}

private struct BrowserList: Decodable {
  struct Browser: Decodable {
    let key: String
    let tty: String?
  }

  let browsers: [Browser]
}

public func browsers(listJSON: Data) -> [BrowserInstance] {
  ((try? JSONDecoder().decode(BrowserList.self, from: listJSON))?.browsers ?? []).compactMap { browser in
    guard let tty = browser.tty.map(normalizedTTY), !tty.isEmpty else { return nil }
    return BrowserInstance(key: browser.key, tty: tty)
  }
}

public func normalizedTTY(_ tty: String) -> String {
  let trimmed = tty.trimmingCharacters(in: .whitespaces)
  return trimmed.hasPrefix("/dev/") ? String(trimmed.dropFirst(5)) : trimmed
}

public func processTTYs(psOutput: Data) -> [Int32: String] {
  var result: [Int32: String] = [:]
  for line in String(decoding: psOutput, as: UTF8.self).split(separator: "\n") {
    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count == 2, let pid = Int32(fields[0]) else { continue }
    let tty = normalizedTTY(String(fields[1]))
    if tty != "??" { result[pid] = tty }
  }
  return result
}

public struct BrowserPane: Equatable, Sendable {
  public var block: String
  public var key: String

  public init(block: String, key: String) {
    self.block = block
    self.key = key
  }
}

public func matchingBrowser(blocks: [String], blockTTYs: [String: String], browsers: [BrowserInstance])
  -> BrowserPane?
{
  for block in blocks {
    guard let tty = blockTTYs[block] else { continue }
    if let browser = browsers.first(where: { $0.tty == tty }) { return BrowserPane(block: block, key: browser.key) }
  }
  return nil
}
