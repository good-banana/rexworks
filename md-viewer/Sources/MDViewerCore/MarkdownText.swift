import Foundation

public func decodeMarkdown(_ data: Data) -> String {
  String(data: data, encoding: .utf8)
    ?? String(data: data, encoding: .windowsCP1252)
    ?? String(data: data, encoding: .isoLatin1)
    ?? String(decoding: data, as: UTF8.self)
}

public func readMarkdown(at url: URL) throws -> String {
  decodeMarkdown(try Data(contentsOf: url))
}
