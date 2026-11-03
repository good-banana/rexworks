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
  private var holding = false
  private var holdToken: String?
  private(set) var pending: [ViewerControlEvent] = []
  public var onEditorMessage: ((EditorMessage) -> Void)?
  public var onLiveFollow: ((_ token: String, _ file: String) -> Void)?

  public init() {}

  public var isHolding: Bool { holding }

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

  public func beginHold(token: String?) {
    holding = true
    holdToken = token
  }

  @discardableResult
  public func endHold() -> EditorMessage? {
    guard holding else { return nil }
    holding = false
    var replayed = Self.replay(pending, handoffToken: holdToken)
    holdToken = nil
    var cursor: EditorMessage?
    if let index = replayed.firstIndex(where: { if case .editor(.cursor) = $0 { true } else { false } }),
      case .editor(let message) = replayed.remove(at: index)
    {
      cursor = message
    }
    pending = replayed
    flush()
    return cursor
  }

  nonisolated static func replay(_ events: [ViewerControlEvent], handoffToken: String?) -> [ViewerControlEvent] {
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
      if isHolding, !enqueueWhileHolding(event) { return }
      pending.append(event)
    } else {
      deliver(event)
    }
  }

  private func enqueueWhileHolding(_ event: ViewerControlEvent) -> Bool {
    guard case .editor(let message) = event else { return true }
    switch message {
    case .edit: return true
    case .cursor(let envelope, _, _, _):
      guard envelope.token == holdToken else { return false }
      pending.removeAll { if case .editor(.cursor) = $0 { true } else { false } }
      return true
    default: return false
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
