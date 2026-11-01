import Foundation
import MDViewerCore

enum AgentsCommand {
  static func skills() -> AgentSkills {
    AgentSkills(home: FileManager.default.homeDirectoryForCurrentUser)
  }

  static func run(_ action: String?) -> Never {
    do {
      switch action {
      case "install":
        print(agentStatusLines(try skills().install()).joined(separator: "\n"))
      case "remove":
        print(agentStatusLines(try skills().remove()).joined(separator: "\n"))
      case "status":
        let reports = skills().status()
        print(agentStatusLines(reports).joined(separator: "\n"))
        exit(agentStatusExitCode(reports))
      default:
        fail("usage: md-viewer agents install|status|remove", status: 64)
      }
    } catch {
      fail("agents \(action ?? "") failed: \(error)", status: 1)
    }
    exit(0)
  }

  static func offerInstall() {
    let outcome = offerAgentInstall(
      isInteractive: isatty(STDIN_FILENO) != 0,
      ask: {
        print("Also teach coding agents to use md-viewer? [y/N] ", terminator: "")
        return readLine()
      },
      install: {
        do {
          print(agentStatusLines(try skills().install()).joined(separator: "\n"))
        } catch {
          FileHandle.standardError.write(Data("agents install failed: \(error)\n".utf8))
        }
      })
    if outcome == .hint {
      print("To teach coding agents to use md-viewer, run: md-viewer agents install")
    }
  }

  static func removeQuietly() {
    do {
      _ = try skills().remove()
    } catch {
      FileHandle.standardError.write(Data("agents remove failed: \(error)\n".utf8))
    }
  }
}
