import Foundation
import MDViewerCore
import MDViewerDisplay
import MDViewerRender

@MainActor
public protocol HandoffTerminal: AnyObject {
  func setHandoffActive(_ active: Bool)
  func suspendInput()
  func waitForInputQueue()
  func readPendingInput() -> [UInt8]
  func leaveRawMode()
  func enterRawMode() -> Bool
  func resumeInput()
  func size() -> PaneSize?
  func spawn(_ launch: EditorLaunch, onExit: @escaping @MainActor (Int32) -> Void) throws
}

@MainActor
public final class HandoffController {
  public enum Result: Equatable, Sendable {
    case exited(Int32)
    case failed
  }

  let host: ViewerHost
  let control: ViewerControl
  let gate: GatedTerminalOutput
  let terminal: HandoffTerminal
  let drainTimeout: UInt64
  public private(set) var launch: EditorLaunch?

  public init(
    host: ViewerHost, control: ViewerControl, gate: GatedTerminalOutput, terminal: HandoffTerminal,
    drainTimeout: UInt64 = ViewerHost.handoffDrainTimeout
  ) {
    self.host = host
    self.control = control
    self.gate = gate
    self.terminal = terminal
    self.drainTimeout = drainTimeout
  }

  public static func status(for result: Result, launch: EditorLaunch) -> (text: String, kind: StatusMessage.Kind) {
    let name = launch.command.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    switch result {
    case .exited(0): return ("Back from \(name)", .info)
    case .exited(let status): return ("\(name) exited with status \(status)", .error)
    case .failed: return ("Could not open \(launch.kind.displayName)", .error)
    }
  }

  public func start(_ launch: EditorLaunch) {
    guard self.launch == nil, !host.handoffActive else { return }
    self.launch = launch
    host.beginHandoff()
    control.beginHold(token: launch.token)
    terminal.setHandoffActive(true)
    gate.closeGate()
    gate.writeBypassingGate(TerminalSequences.restoreModes)
    gate.writeBypassingGate(TerminalColorQuery.primaryDeviceAttributes)
    host.awaitSentinelReply(timeout: drainTimeout) { [weak self] in
      MainActor.assumeIsolated { self?.drained() }
    }
  }

  func drained() {
    guard let launch else { return }
    terminal.suspendInput()
    terminal.waitForInputQueue()
    while !terminal.readPendingInput().isEmpty {}
    gate.writeBypassingGate(TerminalSequences.restoreScreen)
    terminal.leaveRawMode()
    do {
      try terminal.spawn(launch) { [weak self] status in self?.finish(.exited(status)) }
    } catch {
      host.services.log("handoff: could not start \(launch.command.first ?? ""): \(error)")
      finish(.failed)
    }
  }

  func finish(_ result: Result) {
    guard let launch else { return }
    if !terminal.enterRawMode() { host.services.log("handoff: could not configure the terminal") }
    gate.openGate()
    gate.write(
      TerminalSequences.enter + TerminalSequences.enableViewerModes + TerminalSequences.queryInBandResizeReports)
    host.resetInput()
    terminal.resumeInput()
    host.resumeDisplay(size: terminal.size())
    terminal.setHandoffActive(false)
    host.endHandoff(block: launch.block)
    self.launch = nil
    let shown = host.interaction.file
    let cursor = control.endHold()
    host.applyHandoffCursor(cursor, shownBefore: shown)
    let status = Self.status(for: result, launch: launch)
    host.showEditorStatus(status.text, kind: status.kind)
  }
}
