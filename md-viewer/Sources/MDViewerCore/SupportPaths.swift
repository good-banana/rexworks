import CryptoKit
import Foundation

public struct SupportPaths: Sendable {
  public let home: URL

  public init(home: URL) {
    self.home = home
  }

  public var root: URL {
    home.appendingPathComponent("Library/Application Support/md-viewer", isDirectory: true)
  }

  public var configFile: URL { root.appendingPathComponent("config.json") }
  public var handlerLog: URL { root.appendingPathComponent("handler.log") }
  public var viewersDirectory: URL { root.appendingPathComponent("viewers", isDirectory: true) }
  public var viewerLog: URL { root.appendingPathComponent("viewer.log") }

  public var installedApp: URL {
    home.appendingPathComponent("Applications/MD Viewer.app", isDirectory: true)
  }

  public func viewerSocket(block: String) -> URL {
    let digest = SHA256.hash(data: Data(block.utf8))
    let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return viewersDirectory.appendingPathComponent("\(name).sock")
  }
}
