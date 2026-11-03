import Darwin
import Dispatch
import MDViewerCore
import MDViewerDisplay
import MDViewerHost

@MainActor
final class Handoff: HandoffTerminal {
  let input: DispatchSourceRead
  let inputQueue: DispatchQueue
  private var child: HandoffChild?

  init(input: DispatchSourceRead, inputQueue: DispatchQueue) {
    self.input = input
    self.inputQueue = inputQueue
  }

  func setHandoffActive(_ active: Bool) {
    Terminal.handoffActive = active
  }

  func suspendInput() {
    input.suspend()
  }

  func waitForInputQueue() {
    inputQueue.sync {}
  }

  func readPendingInput() -> [UInt8] {
    Terminal.readAvailable(timeoutMilliseconds: 0)
  }

  func leaveRawMode() {
    Terminal.leaveRawMode()
  }

  func enterRawMode() -> Bool {
    Terminal.enterRawMode()
  }

  func resumeInput() {
    input.resume()
  }

  func size() -> PaneSize? {
    Terminal.size()
  }

  func spawn(_ launch: EditorLaunch, onExit: @escaping @MainActor (Int32) -> Void) throws {
    let pid = try HandoffSpawn.spawn(launch.command, environment: launch.environment, directory: launch.directory)
    child = HandoffChild(pid: pid) { [weak self] status in
      MainActor.assumeIsolated {
        self?.child = nil
        onExit(status)
      }
    }
  }
}
