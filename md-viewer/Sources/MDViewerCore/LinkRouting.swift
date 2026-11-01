import CoreGraphics
import Foundation
import UniformTypeIdentifiers

public enum LinkAction: Equatable {
  case openMarkdown(URL, fragment: String?)
  case scrollToAnchor(String)
  case openExternal(URL)
  case ignore
}

private let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"]
private let externalSchemes: Set<String> = ["http", "https", "mailto"]

public func linkAction(href: String, currentFile: URL, fileExists: (URL) -> Bool) -> LinkAction {
  let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.hasPrefix("#") {
    let fragment = decoded(String(trimmed.dropFirst()))
    return fragment.map(LinkAction.scrollToAnchor) ?? .ignore
  }
  guard let scheme = scheme(of: trimmed) else {
    return localAction(reference: trimmed, currentFile: currentFile, fileExists: fileExists)
  }
  if externalSchemes.contains(scheme) {
    return URL(string: trimmed).map(LinkAction.openExternal) ?? .ignore
  }
  if scheme == "file", let url = URL(string: trimmed) {
    return localAction(
      path: url.path, fragment: url.fragment.flatMap(decoded), currentFile: currentFile, fileExists: fileExists)
  }
  return .ignore
}

public func hitTest(_ links: [PageLink], pageX: CGFloat, pageY: CGFloat) -> PageLink? {
  links.first { $0.rect.contains(CGPoint(x: pageX, y: pageY)) }
}

public func cycle(from current: Int?, count: Int, forward: Bool) -> Int? {
  guard count > 0 else { return nil }
  guard let current, (0..<count).contains(current) else { return forward ? 0 : count - 1 }
  return (current + (forward ? 1 : count - 1)) % count
}

private let blockedLocalTypes: [UTType] = [
  .executable, .script, .application, .package, .svg, .html, .xml, .playlist,
]

public func isSafeToOpenLocally(_ url: URL) -> Bool {
  localFileType(url, allowed: [.image, .audiovisualContent, .pdf, .plainText]) != nil
}

public func isPosterCandidate(_ url: URL) -> Bool {
  localFileType(url, allowed: [.audiovisualContent]) != nil
}

private func localFileType(_ url: URL, allowed: [UTType]) -> UTType? {
  let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey]
  guard url.isFileURL, let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
    let type = values.contentType, !FileManager.default.isExecutableFile(atPath: url.path),
    allowed.contains(where: { type.conforms(to: $0) }),
    !blockedLocalTypes.contains(where: { type.conforms(to: $0) })
  else { return nil }
  return type
}

private func scheme(of reference: String) -> String? {
  guard let colon = reference.firstIndex(of: ":") else { return nil }
  let candidate = reference[..<colon]
  guard let first = candidate.first, first.isASCII, first.isLetter,
    candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
  else { return nil }
  return candidate.lowercased()
}

private func decoded(_ text: String) -> String? {
  guard let value = text.removingPercentEncoding, !value.isEmpty else { return nil }
  return value
}

private func localAction(reference: String, currentFile: URL, fileExists: (URL) -> Bool) -> LinkAction {
  let parts = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
  let withoutQuery = parts[0].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
  guard let path = decoded(String(withoutQuery)) else { return .ignore }
  let fragment = parts.count > 1 ? decoded(String(parts[1])) : nil
  return localAction(path: path, fragment: fragment, currentFile: currentFile, fileExists: fileExists)
}

private func localAction(
  path: String, fragment: String?, currentFile: URL, fileExists: (URL) -> Bool
) -> LinkAction {
  guard !path.isEmpty else { return .ignore }
  let absolute = path.hasPrefix("/") ? path : currentFile.deletingLastPathComponent().path + "/" + path
  let url = URL(fileURLWithPath: (absolute as NSString).standardizingPath)
  guard fileExists(url) else { return .ignore }
  if markdownExtensions.contains(url.pathExtension.lowercased()) {
    return .openMarkdown(url, fragment: fragment)
  }
  return .openExternal(url)
}
