import Darwin
import Dispatch
import Foundation

@MainActor
final class FileWatcher {
  private static let debounce = DispatchTimeInterval.milliseconds(100)
  private static let rearmAttempts = 20

  private let url: URL
  private let onChange: () -> Void
  private var source: DispatchSourceFileSystemObject?
  private var changeScheduled = false
  private var stopped = false

  init(url: URL, onChange: @escaping () -> Void) {
    self.url = url
    self.onChange = onChange
    arm(remainingAttempts: Self.rearmAttempts, notify: false)
  }

  func stop() {
    stopped = true
    source?.cancel()
    source = nil
  }

  private func arm(remainingAttempts: Int, notify: Bool) {
    guard !stopped else { return }
    let descriptor = open(url.path, O_EVTONLY)
    guard descriptor >= 0 else {
      if remainingAttempts > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce) {
          MainActor.assumeIsolated { self.arm(remainingAttempts: remainingAttempts - 1, notify: notify) }
        }
      }
      return
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete], queue: .main)
    source.setEventHandler {
      MainActor.assumeIsolated { self.handle(source.data) }
    }
    source.setCancelHandler { close(descriptor) }
    self.source = source
    source.resume()
    if notify { scheduleChange() }
  }

  private func handle(_ events: DispatchSource.FileSystemEvent) {
    guard events.isDisjoint(with: [.rename, .delete]) else {
      source?.cancel()
      source = nil
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce) {
        MainActor.assumeIsolated { self.arm(remainingAttempts: Self.rearmAttempts, notify: true) }
      }
      return
    }
    scheduleChange()
  }

  private func scheduleChange() {
    guard !changeScheduled else { return }
    changeScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce) {
      MainActor.assumeIsolated {
        self.changeScheduled = false
        if !self.stopped { self.onChange() }
      }
    }
  }
}
