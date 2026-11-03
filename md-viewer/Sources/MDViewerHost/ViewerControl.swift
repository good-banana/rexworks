import Foundation
import MDViewerCore

public enum ViewerControlEvent: Equatable, Sendable {
  case open(URL)
  case theme
  case editor(EditorMessage)
}

@MainActor
public final class ViewerControl {
  private var host: ViewerHost?
  private var holdToken: String?
  private(set) var pending: [ViewerControlEvent] = []
  public var onEditorMessage: ((EditorMessage) -> Void)?
  public var onLiveFollow: ((_ token: String, _ file: String) -> Void)?

  public init() {}

  public var isHolding: Bool { holdToken != nil }

  public func attach(_ host: ViewerHost) {
    self.host = host
    if !isHolding { flush() }
  }

  public func open(_ url: URL) {
    receive(.open(url))
  }

  public func themeChanged() {
    receive(.theme)
  }

  public func receive(editor message: EditorMessage) {
    if case .follow(let envelope) = message { onLiveFollow?(envelope.token, envelope.file) }
    receive(.editor(message))
  }

  public func beginHold(token: String) {
    holdToken = token
  }

  public func endHold() {
    guard let token = holdToken else { return }
    holdToken = nil
    pending = Self.replay(pending, handoffToken: token)
    flush()
  }

  nonisolated static func replay(_ events: [ViewerControlEvent], handoffToken: String) -> [ViewerControlEvent] {
    var lastCursor: Int?
    for (index, event) in events.enumerated() {
      if case .editor(.cursor(let envelope, _, _, _)) = event, envelope.token == handoffToken { lastCursor = index }
    }
    return events.enumerated().compactMap { index, event in
      switch event {
      case .editor(.edit): event
      case .editor(.cursor): index == lastCursor ? event : nil
      case .editor: nil
      case .open, .theme: event
      }
    }
  }

  public nonisolated func listen(on socket: URL, status: ViewerStatus, buffersDirectory: URL? = nil) throws
    -> ViewerSocketServer
  {
    try ViewerSocketServer(
      socket: socket, status: status, buffersDirectory: buffersDirectory,
      onOpen: { url in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self.open(url) }
        }
      },
      onTheme: {
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self.themeChanged() }
        }
      },
      onEditor: { message in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self.receive(editor: message) }
        }
      })
  }

  private func receive(_ event: ViewerControlEvent) {
    if host == nil || isHolding || !pending.isEmpty {
      if event == .theme, pending.last == .theme { return }
      pending.append(event)
    } else {
      deliver(event)
    }
  }

  private func flush() {
    while host != nil, !isHolding, !pending.isEmpty { deliver(pending.removeFirst()) }
  }

  private func deliver(_ event: ViewerControlEvent) {
    switch event {
    case .open(let url): host?.open(url)
    case .theme: host?.themeChanged()
    case .editor(let message): onEditorMessage?(message)
    }
  }
}
