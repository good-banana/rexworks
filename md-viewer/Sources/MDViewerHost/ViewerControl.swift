import Foundation
import MDViewerCore

@MainActor
public final class ViewerControl {
  private var host: ViewerHost?
  private(set) var pendingOpens: [URL] = []
  private(set) var pendingTheme = false

  public init() {}

  public func attach(_ host: ViewerHost) {
    self.host = host
    for url in pendingOpens { host.open(url) }
    if pendingTheme { host.themeChanged() }
    pendingOpens = []
    pendingTheme = false
  }

  public func open(_ url: URL) {
    if let host { host.open(url) } else { pendingOpens.append(url) }
  }

  public func themeChanged() {
    if let host { host.themeChanged() } else { pendingTheme = true }
  }

  public nonisolated func listen(on socket: URL, status: ViewerStatus) throws -> ViewerSocketServer {
    try ViewerSocketServer(
      socket: socket, status: status,
      onOpen: { url in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self.open(url) }
        }
      },
      onTheme: {
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self.themeChanged() }
        }
      })
  }
}
