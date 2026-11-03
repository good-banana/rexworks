import Foundation

public let agentStubVersion = "1"
public let agentStubMarkerKey = "md-viewer-stub"

public let agentStub = """
  ---
  name: md-viewer
  description: Use when you have written or substantially updated a Markdown file for the user (plan, report, design doc, README), or when the user asks to see, open or preview a Markdown file. Opens it in a Rex preview pane with md-viewer.
  metadata:
    \(agentStubMarkerKey): "\(agentStubVersion)"
  ---
  <!-- Installed by "md-viewer agents install". Remove it with "md-viewer agents remove". -->

  Run `md-viewer agent-guide` and follow the guide it prints. The guide comes from
  the installed md-viewer, so it describes the behavior of that version.

  If the command fails, md-viewer is not available. Mention the file path and continue.

  """

public let agentGuide = """
  md-viewer opens Markdown files in a Rex preview pane.

  When to open a preview:
  - After writing or substantially updating a Markdown file meant for the user: plans, reports, design docs, READMEs.
  - When the user asks to see or open a .md file.

  When not to:
  - Files you only read or lightly edit, scratch notes, or bulk opens. Open one preview per deliverable.

  How:
  - Run `md-viewer open /absolute/path/to/file.md`.
  - The preview opens without taking focus: the tab's first preview beside the pane the command runs in (your own pane), later ones below the newest preview. A file that is already shown reuses its preview.
  - Add `--replace` when updating or revising the same deliverable, so the preview you opened last switches to it instead of a new pane opening.
  - Add `--new` when the user should compare documents side by side, so each one opens in its own pane.
  - When unsure, use no flag.
  - Always also print the file path in your reply.

  If the command fails, or md-viewer or Rex is unavailable, mention the file path and continue. Do not retry, use another viewer, or install anything.

  """

public struct AgentSkillTarget: Sendable, Equatable {
  public let agents: String
  public let parent: String

  public var relativeDirectory: String { "\(parent)/skills/md-viewer" }

  public init(agents: String, parent: String) {
    self.agents = agents
    self.parent = parent
  }
}

public let agentSkillTargets = [
  AgentSkillTarget(agents: "Claude Code", parent: ".claude"),
  AgentSkillTarget(agents: "Codex, Pi, OpenCode, Devin CLI", parent: ".agents"),
  AgentSkillTarget(agents: "cursor-agent", parent: ".cursor"),
]

public enum AgentSkillState: String, Sendable, Equatable {
  case installed, current, outdated, missing, skipped, foreign
}

public struct AgentSkillReport: Sendable, Equatable {
  public let target: AgentSkillTarget
  public let state: AgentSkillState
  public let directory: URL
}

public func stubVersion(of content: String) -> String? {
  guard content.hasPrefix("---\n"), let end = content.range(of: "\n---\n") else { return nil }
  let frontmatter = content[content.startIndex..<end.lowerBound]
  let quotes = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))
  for line in frontmatter.split(separator: "\n") {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("\(agentStubMarkerKey):") else { continue }
    return trimmed.dropFirst(agentStubMarkerKey.count + 1).trimmingCharacters(in: quotes)
  }
  return nil
}

public struct AgentSkills: Sendable {
  public let home: URL
  public let targets: [AgentSkillTarget]

  public init(home: URL, targets: [AgentSkillTarget] = agentSkillTargets) {
    self.home = home
    self.targets = targets
  }

  private func directory(_ target: AgentSkillTarget) -> URL {
    home.appendingPathComponent(target.relativeDirectory, isDirectory: true)
  }

  private func file(_ target: AgentSkillTarget) -> URL {
    directory(target).appendingPathComponent("SKILL.md")
  }

  private func parentExists(_ target: AgentSkillTarget) -> Bool {
    var isDirectory: ObjCBool = false
    let path = home.appendingPathComponent(target.parent).path
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func classify(_ target: AgentSkillTarget) -> AgentSkillState {
    guard parentExists(target) else { return .skipped }
    guard let data = try? Data(contentsOf: file(target)) else {
      return FileManager.default.fileExists(atPath: directory(target).path) ? .foreign : .missing
    }
    guard let version = stubVersion(of: String(decoding: data, as: UTF8.self)) else {
      return .foreign
    }
    return version == agentStubVersion ? .current : .outdated
  }

  public func status() -> [AgentSkillReport] {
    targets.map { AgentSkillReport(target: $0, state: classify($0), directory: directory($0)) }
  }

  public func install() throws -> [AgentSkillReport] {
    try targets.map { target in
      var state = classify(target)
      if state == .missing || state == .outdated {
        try FileManager.default.createDirectory(
          at: directory(target), withIntermediateDirectories: true)
        try Data(agentStub.utf8).write(to: file(target), options: .atomic)
        state = .installed
      }
      return AgentSkillReport(target: target, state: state, directory: directory(target))
    }
  }

  public func remove() throws -> [AgentSkillReport] {
    try targets.map { target in
      var state = classify(target)
      if state == .current || state == .outdated {
        try FileManager.default.removeItem(at: directory(target))
        state = .missing
      }
      return AgentSkillReport(target: target, state: state, directory: directory(target))
    }
  }
}

public enum AgentOfferOutcome: Equatable, Sendable {
  case installed
  case declined
  case hint
}

public func offerAgentInstall(
  isInteractive: Bool, ask: () -> String?, install: () -> Void
) -> AgentOfferOutcome {
  guard isInteractive else { return .hint }
  let answer = ask()?.trimmingCharacters(in: .whitespaces).lowercased()
  guard answer == "y" || answer == "yes" else { return .declined }
  install()
  return .installed
}

public func agentStatusLines(_ reports: [AgentSkillReport]) -> [String] {
  reports.map { "\($0.state.rawValue) \($0.directory.path) (\($0.target.agents))" }
}

public func agentStatusExitCode(_ reports: [AgentSkillReport]) -> Int32 {
  reports.contains { $0.state == .outdated || $0.state == .foreign } ? 1 : 0
}
