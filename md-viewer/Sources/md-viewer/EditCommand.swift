import Foundation
import MDViewerCore

enum EditCommand {
  static func run(_ arguments: [String]) -> Never {
    switch EditArguments.parse(arguments) {
    case .failure(let error):
      fail(error.description, status: 64)
    case .success(let edit):
      do {
        let paths = currentPaths()
        let prepared = try OpenCommand.prepare(OpenArguments(file: edit.file))
        let mode = edit.requestMode(editMode: SettingsStore.load(paths).editMode)
        let delivery = try openAndDeliverEdit(
          lock: paths.openLock, open: { try OpenCommand.open(prepared, requiresBlock: true) },
          deliver: { block in
            deliverWithRetry {
              ViewerSocketClient.sendEdit(mode: mode, line: edit.line, to: paths.viewerSocket(block: block))
            }
          })
        switch delivery {
        case .noPreview: fail("could not find the preview block for \(edit.file)", status: 1)
        case .unreachable: fail("could not reach the preview to start editing", status: 1)
        case .delivered: exit(0)
        }
      } catch {
        fail("\(error)", status: 1)
      }
    }
  }
}
