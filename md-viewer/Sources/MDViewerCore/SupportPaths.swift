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
  public var tileDirectory: URL { root.appendingPathComponent("tiles", isDirectory: true) }

  public var installedApp: URL {
    home.appendingPathComponent("Applications/MD Viewer.app", isDirectory: true)
  }

  public func viewerSocket(block: String) -> URL {
    viewersDirectory.appendingPathComponent("\(block).sock")
  }
}
