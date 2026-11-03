import XCTest

@testable import MDViewerCore

final class AgentSkillTests: XCTestCase {
  var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  func makeParent(_ name: String) throws {
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(name), withIntermediateDirectories: true)
  }

  func skillFile(_ parent: String) -> URL {
    home.appendingPathComponent("\(parent)/skills/md-viewer/SKILL.md")
  }

  func states(_ reports: [AgentSkillReport]) -> [AgentSkillState] { reports.map(\.state) }

  func writeSkill(_ parent: String, _ content: String) throws {
    try FileManager.default.createDirectory(
      at: skillFile(parent).deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: skillFile(parent), atomically: true, encoding: .utf8)
  }

  var outdatedStub: String {
    agentStub.replacingOccurrences(of: "\"\(agentStubVersion)\"", with: "\"0\"")
  }

  func testStubFrontmatterAndBody() {
    XCTAssertTrue(agentStub.hasPrefix("---\nname: md-viewer\ndescription: "))
    XCTAssertEqual(stubVersion(of: agentStub), agentStubVersion)
    XCTAssertTrue(agentStub.contains("`md-viewer agent-guide`"))
    XCTAssertTrue(agentStub.contains("Installed by \"md-viewer agents install\""))
  }

  func testGuideContainsOpenCommandAndFallbackRule() {
    XCTAssertTrue(agentGuide.contains("md-viewer open /absolute/path/to/file.md"))
    XCTAssertTrue(agentGuide.contains("Do not retry, use another viewer, or install anything."))
    XCTAssertTrue(agentGuide.contains("print the file path"))
    XCTAssertTrue(agentGuide.contains("beside the pane the command runs in (your own pane)"))
    XCTAssertFalse(agentGuide.contains("focused in Rex"))
    XCTAssertFalse(agentGuide.contains("reuse that tab's preview"))
    XCTAssertTrue(agentGuide.contains("`--replace` when updating or revising the same deliverable"))
    XCTAssertTrue(agentGuide.contains("`--new` when the user should compare documents side by side"))
    XCTAssertTrue(agentGuide.contains("When unsure, use no flag."))
  }

  func testGuideCoversSettingsAndEditing() {
    XCTAssertTrue(
      agentGuide.contains(
        "run `md-viewer config set editor <command>` (for example `nvim`, `hx`, `code`) or `md-viewer config set edit-mode split|here`. Run `md-viewer config` to show the current values. Do not edit config.json."
      ))
    XCTAssertTrue(agentGuide.contains("Do not open editor panes or run `md-viewer edit` unless the user asks."))
    XCTAssertTrue(
      agentGuide.contains(
        "If a write is refused because the file changed, re-read it and never overwrite the user's saved changes."))
    XCTAssertEqual(agentStubVersion, "1")
  }

  func testStubVersionRejectsForeignContent() {
    XCTAssertNil(stubVersion(of: "---\nname: md-viewer\n---\nbody"))
    XCTAssertNil(stubVersion(of: "no frontmatter"))
  }

  func testInstallWritesOnlyWhereParentExists() throws {
    try makeParent(".claude")
    try makeParent(".cursor")
    let reports = try AgentSkills(home: home).install()
    XCTAssertEqual(states(reports), [.installed, .skipped, .installed])
    XCTAssertEqual(try String(contentsOf: skillFile(".claude"), encoding: .utf8), agentStub)
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents").path))
  }

  func testInstallIsIdempotent() throws {
    try makeParent(".agents")
    let skills = AgentSkills(home: home)
    _ = try skills.install()
    XCTAssertEqual(states(try skills.install()), [.skipped, .current, .skipped])
  }

  func testInstallRefusesForeignFile() throws {
    try makeParent(".claude")
    try writeSkill(".claude", "mine")
    XCTAssertEqual(states(try AgentSkills(home: home).install()).first, .foreign)
    XCTAssertEqual(try String(contentsOf: skillFile(".claude"), encoding: .utf8), "mine")
  }

  func testInstallUpgradesOutdatedStub() throws {
    try makeParent(".claude")
    try writeSkill(".claude", outdatedStub)
    let skills = AgentSkills(home: home)
    XCTAssertEqual(states(skills.status()).first, .outdated)
    XCTAssertEqual(states(try skills.install()).first, .installed)
    XCTAssertEqual(try String(contentsOf: skillFile(".claude"), encoding: .utf8), agentStub)
  }

  func testStatusStates() throws {
    try makeParent(".claude")
    try makeParent(".agents")
    try makeParent(".cursor")
    let skills = AgentSkills(home: home)
    XCTAssertEqual(states(skills.status()), [.missing, .missing, .missing])
    _ = try skills.install()
    try writeSkill(".agents", "mine")
    try writeSkill(".cursor", outdatedStub)
    let reports = skills.status()
    XCTAssertEqual(states(reports), [.current, .foreign, .outdated])
    XCTAssertEqual(agentStatusExitCode(reports), 1)
  }

  func testStatusSkippedWhenNoAgentsInstalled() {
    let reports = AgentSkills(home: home).status()
    XCTAssertEqual(states(reports), [.skipped, .skipped, .skipped])
    XCTAssertEqual(agentStatusExitCode(reports), 0)
  }

  func testRemoveDeletesMarkedOnly() throws {
    try makeParent(".claude")
    try makeParent(".agents")
    let skills = AgentSkills(home: home)
    _ = try skills.install()
    try writeSkill(".agents", "mine")
    XCTAssertEqual(states(try skills.remove()), [.missing, .foreign, .skipped])
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: skillFile(".claude").deletingLastPathComponent().path))
    XCTAssertEqual(try String(contentsOf: skillFile(".agents"), encoding: .utf8), "mine")
  }

  func testStatusLinesNameDirectoryAndAgents() throws {
    try makeParent(".cursor")
    let lines = agentStatusLines(AgentSkills(home: home).status())
    XCTAssertEqual(lines.count, 3)
    XCTAssertTrue(lines[2].hasPrefix("missing "))
    XCTAssertTrue(lines[2].hasSuffix("/.cursor/skills/md-viewer (cursor-agent)"))
  }

  func testOfferYesInstalls() {
    var installed = false
    let outcome = offerAgentInstall(isInteractive: true, ask: { "y" }, install: { installed = true })
    XCTAssertEqual(outcome, .installed)
    XCTAssertTrue(installed)
  }

  func testOfferNoOrBlankDeclines() {
    var installed = false
    for answer in ["n", "", nil] as [String?] {
      XCTAssertEqual(
        offerAgentInstall(isInteractive: true, ask: { answer }, install: { installed = true }),
        .declined)
    }
    XCTAssertFalse(installed)
  }

  func testOfferNonInteractiveHintsWithoutAsking() {
    var asked = false
    let outcome = offerAgentInstall(
      isInteractive: false,
      ask: {
        asked = true
        return "y"
      }, install: {})
    XCTAssertEqual(outcome, .hint)
    XCTAssertFalse(asked)
  }
}
