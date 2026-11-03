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
        let open = OpenArguments(file: edit.file)
        guard let block = try OpenCommand.open(open, requiresBlock: true) else {
          fail("could not find the preview block for \(edit.file)", status: 1)
        }
        let mode = edit.requestMode(editMode: SettingsStore.load(paths).editMode)
        let socket = paths.viewerSocket(block: block)
        let delivered = deliverWithRetry {
          ViewerSocketClient.sendEdit(mode: mode, line: edit.line, to: socket)
        }
        guard delivered else { fail("could not reach the preview to start editing", status: 1) }
        exit(0)
      } catch {
        fail("\(error)", status: 1)
      }
    }
  }
}
