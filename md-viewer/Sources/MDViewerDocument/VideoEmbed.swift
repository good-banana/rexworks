import Foundation

public struct VideoEmbed: Hashable, Sendable {
  public var href: String
  public var poster: String?

  public init?(source: String) {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let absolute = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
    guard let url = URL(string: absolute), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
      var host = url.host?.lowercased()
    else { return nil }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    let watched =
      url.pathComponents.last == "watch"
      ? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value : nil
    guard let id = watched ?? url.pathComponents.last(where: { $0 != "/" }),
      id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else { return nil }
    switch host {
    case "youtube.com", "youtube-nocookie.com", "youtu.be":
      href = "https://www.youtube.com/watch?v=\(id)"
      poster = "https://img.youtube.com/vi/\(id)/hqdefault.jpg"
    case "player.vimeo.com", "vimeo.com":
      href = "https://vimeo.com/\(id)"
      poster = nil
    default:
      return nil
    }
  }
}
