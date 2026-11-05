import Foundation
import XCTest

@testable import MDViewerCore

final class ShellDirectoryReportingTests: XCTestCase {
  private var directory: URL!
  private var home: URL!

  override func setUpWithError() throws {
    directory = testScratchDirectory()
    home = directory.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func setup(
    login: String? = "/bin/zsh", installed: Set<String> = ["zsh", "bash"], environment: [String: String] = [:],
    runner: ProcessRunning? = nil
  ) -> ShellSetup {
    ShellSetup(
      home: home, environment: environment, loginShell: login,
      locate: { installed.contains($0) ? "/fake/bin/\($0)" : nil }, runner: runner, synchronize: { _ in })
  }

  private func file(_ name: String) -> URL { home.appendingPathComponent(name) }

  private func write(_ name: String, _ text: String) throws {
    try text.write(to: file(name), atomically: true, encoding: .utf8)
  }

  private func read(_ name: String) throws -> String {
    try String(contentsOf: file(name), encoding: .utf8)
  }

  private func exists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: file(name).path)
  }

  func testBlocksAreStaticAndGuardedByRexAndInteractivity() {
    for block in [ShellDirectoryReporting.zsh, ShellDirectoryReporting.bash] {
      XCTAssertTrue(block.text.hasPrefix("# >>> md-viewer: report the folder to Rex from "))
      XCTAssertTrue(block.text.hasPrefix(block.beginMarker + "\n"))
      XCTAssertTrue(block.text.hasSuffix("\n" + block.endMarker))
      XCTAssertTrue(block.text.contains("${REX_BLOCK-}${REX_SESSION-}"))
      XCTAssertFalse(block.text.contains("\t"))
      XCTAssertFalse(block.text.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.hasSuffix(" ") })
    }
    XCTAssertTrue(ShellDirectoryReporting.zsh.text.contains("-o interactive"))
    XCTAssertTrue(ShellDirectoryReporting.zsh.text.contains("add-zsh-hook precmd __md_viewer_osc7"))
    XCTAssertTrue(ShellDirectoryReporting.zsh.text.contains("add-zsh-hook chpwd __md_viewer_osc7_chpwd"))
    XCTAssertTrue(ShellDirectoryReporting.bash.text.contains("case $- in"))
    XCTAssertTrue(ShellDirectoryReporting.fish.hasPrefix(ShellDirectoryReporting.beginMarker(.fish) + "\n"))
    XCTAssertTrue(ShellDirectoryReporting.fish.contains("status is-interactive"))
    XCTAssertTrue(ShellDirectoryReporting.fish.contains("status is-command-substitution"))
  }

  func testFishVersionDecidesWhetherItReportsNatively() {
    XCTAssertTrue(ShellDirectoryReporting.fishEmitsNatively(version: "fish, version 4.0.2\n"))
    XCTAssertTrue(ShellDirectoryReporting.fishEmitsNatively(version: "fish, version 4.1.0-123-gabc"))
    XCTAssertFalse(ShellDirectoryReporting.fishEmitsNatively(version: "fish, version 3.7.1"))
    XCTAssertFalse(ShellDirectoryReporting.fishEmitsNatively(version: "garbage"))
  }

  func testLoginShellNamesMapToShells() {
    XCTAssertEqual(ReportingShell(executable: "/bin/zsh"), .zsh)
    XCTAssertEqual(ReportingShell(executable: "/opt/homebrew/bin/bash"), .bash)
    XCTAssertEqual(ReportingShell(executable: "/opt/homebrew/bin/fish"), .fish)
    XCTAssertEqual(ReportingShell(executable: "/opt/homebrew/bin/nu"), .nushell)
    XCTAssertNil(ReportingShell(executable: "/bin/tcsh"))
  }

  func testZshInstallCreatesTheZshrcAndIsIdempotent() throws {
    let outcome = setup().install()
    XCTAssertEqual(outcome.changes, [.init(shell: .zsh, files: [file(".zshrc")])])
    XCTAssertEqual(outcome.failures, [])
    XCTAssertEqual(try read(".zshrc"), setup().createdBlock(.zsh).text + "\n")
    XCTAssertTrue(try read(".zshrc").contains(ShellDirectoryReporting.zsh.text.components(separatedBy: "\n")[1]))
    XCTAssertEqual(setup().install(), .init(), "a second install changes nothing")
    XCTAssertFalse(exists(".bashrc"), "bash is not the login shell and has no rc file")
    XCTAssertFalse(exists(".bash_profile"))
  }

  func testZshInstallFollowsZdotdir() throws {
    let zdotdir = directory.appendingPathComponent("zdot")
    let outcome = setup(environment: ["ZDOTDIR": zdotdir.path]).install()
    let zshrc = zdotdir.appendingPathComponent(".zshrc")
    XCTAssertEqual(outcome.changes, [.init(shell: .zsh, files: [zshrc])])
    XCTAssertTrue(try String(contentsOf: zshrc, encoding: .utf8).contains(ShellDirectoryReporting.zsh.beginMarker))
    XCTAssertFalse(exists(".zshrc"))
    XCTAssertEqual(setup(environment: ["ZDOTDIR": ""]).zshrc, file(".zshrc"))
  }

  func testZshrcComesFromZshItselfSoZshenvSettingsCount() throws {
    let zdotdir = directory.appendingPathComponent("config/zsh")
    let runner = ScriptedRunner(stdout: "noise from zshenv\n\(zdotdir.path)\n") { _, _ in 0 }
    let shells = setup(environment: ["ZDOTDIR": ""], runner: runner)
    XCTAssertEqual(shells.zshrc, zdotdir.appendingPathComponent(".zshrc"))
    XCTAssertEqual(runner.calls.first?.arguments, ["-c", #"print -r -- "${ZDOTDIR:-$HOME}""#])
    XCTAssertEqual(setup(runner: ScriptedRunner(stdout: "relative\n") { _, _ in 0 }).zshrc, file(".zshrc"))
    XCTAssertEqual(setup(runner: ScriptedRunner(stdout: "/x\n") { _, _ in 1 }).zshrc, file(".zshrc"))

    try write(".zshrc", "a=1\n" + ShellDirectoryReporting.zsh.text + "\n")
    let installed = shells.install()
    XCTAssertEqual(installed.changes.first, .init(shell: .zsh, files: [zdotdir.appendingPathComponent(".zshrc")]))
    let removed = shells.remove()
    XCTAssertEqual(
      removed.changes,
      [.init(shell: .zsh, files: [zdotdir.appendingPathComponent(".zshrc"), file(".zshrc")])],
      "a block in ~/.zshrc from an earlier setup is removed too")
    XCTAssertEqual(try read(".zshrc"), "a=1\n")
  }

  func testRemovalDeletesRcFilesThatOnlyHeldTheBlock() throws {
    setup(login: "/bin/bash", installed: ["bash"]).install()
    XCTAssertTrue(exists(".bash_profile"))
    setup(login: "/bin/bash").remove()
    XCTAssertFalse(exists(".bash_profile"), "an empty ~/.bash_profile would hide ~/.profile from bash")
    XCTAssertFalse(exists(".bashrc"))

    try write(".bash_profile", "")
    try write(".profile", "export A=1\n")
    setup(login: "/bin/bash", installed: ["bash"]).install()
    XCTAssertTrue(try read(".bash_profile").hasPrefix(ShellDirectoryReporting.bash.text))
    setup(login: "/bin/bash").remove()
    XCTAssertTrue(exists(".bash_profile"), "an empty ~/.bash_profile that was there before setup is kept")
    XCTAssertEqual(try read(".bash_profile"), "")
    try FileManager.default.removeItem(at: file(".bash_profile"))

    let target = directory.appendingPathComponent("dotfiles/bash_profile")
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (setup().createdBlock(.bash).text + "\n").write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: file(".bash_profile"), withDestinationURL: target)
    XCTAssertEqual(setup().remove().changes, [.init(shell: .bash, files: [file(".bash_profile")])])
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file(".bash_profile").path), target.path)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "")
  }

  func testInstallAndRemoveKeepTheUsersContent() throws {
    let mine = "eval \"$(oh-my-posh init zsh)\"\neval \"$(mise activate zsh)\"\n"
    try write(".zshrc", mine)
    setup().install()
    let installed = try read(".zshrc")
    XCTAssertTrue(installed.hasPrefix(mine))
    XCTAssertEqual(installed.components(separatedBy: ShellDirectoryReporting.zsh.beginMarker).count, 2)
    XCTAssertEqual(setup().remove().changes, [.init(shell: .zsh, files: [file(".zshrc")])])
    XCTAssertEqual(try read(".zshrc"), mine)
    XCTAssertEqual(setup().remove(), .init())
  }

  func testAStaleBlockInTheMiddleIsReplacedAndContentAfterItIsKept() throws {
    try write(
      ".zshrc",
      "a\n\n\(ShellDirectoryReporting.zsh.beginMarker)\nold\n\(ShellDirectoryReporting.zsh.endMarker)\n\nb\n")
    setup().install()
    let text = try read(".zshrc")
    XCTAssertFalse(text.contains("\nold\n"))
    XCTAssertTrue(text.hasPrefix("a\n\nb\n"))
    XCTAssertTrue(text.hasSuffix(ShellDirectoryReporting.zsh.text + "\n"))
  }

  func testOtherShellsRcFilesAreChangedOnlyWhenTheyExist() throws {
    try write(".bashrc", "export A=1\n")
    try write(".bash_profile", "[ -f ~/.bashrc ] && . ~/.bashrc\n")
    let outcome = setup().install()
    XCTAssertEqual(
      outcome.changes,
      [
        .init(shell: .zsh, files: [file(".zshrc")]),
        .init(shell: .bash, files: [file(".bashrc"), file(".bash_profile")]),
      ])
    XCTAssertTrue(try read(".bashrc").hasPrefix("export A=1\n\n" + ShellDirectoryReporting.bash.beginMarker))
    XCTAssertTrue(try read(".bash_profile").contains(ShellDirectoryReporting.bash.text))
  }

  func testOneRcFileSharedByZshAndBashGetsBothBlocks() throws {
    try write(".bashrc", "export A=1\n")
    try FileManager.default.createSymbolicLink(at: file(".zshrc"), withDestinationURL: file(".bashrc"))
    XCTAssertEqual(setup().install().failures, [])
    let text = try read(".bashrc")
    XCTAssertTrue(text.contains(ShellDirectoryReporting.zsh.text))
    XCTAssertTrue(text.contains(ShellDirectoryReporting.bash.text))
    XCTAssertEqual(setup().install(), .init(), "a second install changes nothing")
    XCTAssertEqual(setup().doctorLines(rexPath: nil).map(\.level), [.ok])
    setup().remove()
    XCTAssertEqual(try read(".bashrc"), "export A=1\n")
  }

  func testADanglingRcSymlinkIsLeftAlone() throws {
    let missing = directory.appendingPathComponent("dotfiles/zshrc")
    try FileManager.default.createSymbolicLink(at: file(".zshrc"), withDestinationURL: missing)
    let outcome = setup().install()
    XCTAssertEqual(outcome.changes, [])
    XCTAssertEqual(outcome.failures.map(\.file), [file(".zshrc")])
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file(".zshrc").path), missing.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
  }

  func testDoctorLooksForTheLoginShellsOwnBlock() throws {
    try write(".zshrc", ShellDirectoryReporting.bash.text + "\n")
    XCTAssertEqual(setup().doctorLines(rexPath: nil).map(\.level), [.fail])
  }

  func testAbsentShellsAreSkipped() throws {
    try write(".bashrc", "export A=1\n")
    let outcome = setup(installed: []).install()
    XCTAssertEqual(outcome.changes, [.init(shell: .zsh, files: [file(".zshrc")])], "the login shell still counts")
    XCTAssertEqual(try read(".bashrc"), "export A=1\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: setup().fishFile.path))
  }

  func testBashLoginShellGetsBashrcAndBashProfile() throws {
    let outcome = setup(login: "/bin/bash", installed: ["bash"]).install()
    XCTAssertEqual(outcome.changes, [.init(shell: .bash, files: [file(".bashrc"), file(".bash_profile")])])
    XCTAssertFalse(exists(".zshrc"))
    XCTAssertEqual(try read(".bash_profile"), setup().createdBlock(.bash).text + "\n")
    XCTAssertEqual(setup(login: "/bin/bash", installed: ["bash"]).install(), .init(), "the created marker survives")
  }

  func testBashUsesTheLoginFileBashWouldRead() throws {
    try write(".profile", "export PATH=\"$HOME/bin:$PATH\"\n")
    let outcome = setup(login: "/bin/bash", installed: ["bash"]).install()
    XCTAssertEqual(outcome.changes, [.init(shell: .bash, files: [file(".bashrc"), file(".profile")])])
    XCTAssertFalse(exists(".bash_profile"), "creating it would hide ~/.profile from bash")
    try write(".bash_login", "x=1\n")
    XCTAssertEqual(
      setup(login: "/bin/bash", installed: ["bash"]).install().changes,
      [.init(shell: .bash, files: [file(".bash_login")])], "bash now reads ~/.bash_login instead of ~/.profile")
    XCTAssertEqual(
      setup(login: "/bin/bash").remove().changes,
      [.init(shell: .bash, files: [file(".bashrc"), file(".bash_login"), file(".profile")])])
    XCTAssertEqual(try read(".profile"), "export PATH=\"$HOME/bin:$PATH\"\n")
    XCTAssertEqual(try read(".bash_login"), "x=1\n")
  }

  func testFilesThatCannotBeEditedAreLeftAloneAndReported() throws {
    let original = Data([0x23, 0x20, 0xe9, 0x0a])
    try original.write(to: file(".zshrc"))
    let outcome = setup().install()
    XCTAssertEqual(outcome.changes, [])
    XCTAssertEqual(outcome.failures, [.init(file: file(".zshrc"), reason: "it is not valid UTF-8")])
    XCTAssertEqual(try Data(contentsOf: file(".zshrc")), original)
    XCTAssertEqual(
      shellFailureLines(outcome, installing: true),
      ["Left \(file(".zshrc").path) unchanged because it is not valid UTF-8. Folder reporting was not set up."])

    try write(".zshrc", "a\n\(ShellDirectoryReporting.zsh.beginMarker)\nhalf\n")
    XCTAssertEqual(setup().remove().failures.map(\.reason), ["\(ManagedFileError.unterminatedBlock)"])
    XCTAssertEqual(try read(".zshrc"), "a\n\(ShellDirectoryReporting.zsh.beginMarker)\nhalf\n")
  }

  func testACandidateThatFailsTheShellsSyntaxCheckIsNotWritten() throws {
    try write(".zshrc", "a=1\n")
    let runner = ScriptedRunner { _, arguments in arguments.last == self.file(".zshrc").path ? 0 : 1 }
    let outcome = setup(runner: runner).install()
    XCTAssertEqual(outcome.changes, [])
    XCTAssertEqual(outcome.failures.count, 1)
    XCTAssertEqual(try read(".zshrc"), "a=1\n")
    XCTAssertEqual(
      runner.calls.map(\.arguments.first).filter { $0 != "-c" }, ["-fn", "-fn"], "the original, then the candidate")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [".zshrc"])
  }

  func testAnOriginalThatAlreadyFailsTheCheckDoesNotBlockTheEdit() throws {
    try write(".zshrc", "a=1\n")
    let runner = ScriptedRunner { _, _ in 1 }
    XCTAssertEqual(setup(runner: runner).install().changes.count, 1)
    XCTAssertEqual(runner.calls.filter { $0.arguments.first == "-fn" }.count, 1)
  }

  func testFishGetsAConfFileOnlyWhenItDoesNotReportNatively() throws {
    let old = ScriptedRunner(stdout: "fish, version 3.7.1\n") { _, _ in 0 }
    let fishFile = setup().fishFile
    XCTAssertEqual(fishFile, home.appendingPathComponent(".config/fish/conf.d/md-viewer-rex-folder.fish"))
    let outcome = setup(login: "/opt/homebrew/bin/fish", installed: ["fish"], runner: old).install()
    XCTAssertEqual(outcome.changes, [.init(shell: .fish, files: [fishFile])])
    XCTAssertEqual(try String(contentsOf: fishFile, encoding: .utf8), ShellDirectoryReporting.fish)
    XCTAssertEqual(setup(login: "/opt/homebrew/bin/fish", installed: ["fish"], runner: old).install(), .init())
    XCTAssertEqual(setup().remove().changes, [.init(shell: .fish, files: [fishFile])])
    XCTAssertFalse(FileManager.default.fileExists(atPath: fishFile.path))

    let new = ScriptedRunner(stdout: "fish, version 4.0.2\n") { _, _ in 0 }
    XCTAssertEqual(setup(login: "/opt/homebrew/bin/fish", installed: ["fish"], runner: new).install(), .init())
    XCTAssertFalse(FileManager.default.fileExists(atPath: fishFile.path))
  }

  func testFishConfFileFollowsXdgConfigHome() {
    let config = directory.appendingPathComponent("xdg")
    XCTAssertEqual(
      setup(environment: ["XDG_CONFIG_HOME": config.path]).fishFile,
      config.appendingPathComponent("fish/conf.d/md-viewer-rex-folder.fish"))
  }

  func testAFishFileMdViewerDidNotWriteIsKept() throws {
    let fishFile = setup().fishFile
    try FileManager.default.createDirectory(at: fishFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "set -x MINE 1\n".write(to: fishFile, atomically: true, encoding: .utf8)
    let old = ScriptedRunner(stdout: "fish, version 3.7.1\n") { _, _ in 0 }
    let outcome = setup(installed: ["fish"], runner: old).install()
    XCTAssertEqual(outcome.failures.map(\.file), [fishFile])
    XCTAssertFalse(outcome.changes.contains { $0.shell == .fish })
    XCTAssertFalse(setup().remove().changes.contains { $0.shell == .fish })
    XCTAssertEqual(try String(contentsOf: fishFile, encoding: .utf8), "set -x MINE 1\n")
  }

  func testNushellNeedsNoChanges() {
    XCTAssertEqual(setup(login: "/opt/homebrew/bin/nu", installed: ["nu"]).install(), .init())
  }

  func testSetupLinesNameEachChangedShell() {
    let outcome = ShellSetup.Outcome(
      changes: [
        .init(shell: .zsh, files: [file(".zshrc")]), .init(shell: .bash, files: [file(".bashrc"), file(".profile")]),
      ])
    XCTAssertEqual(
      shellSetupLines(outcome, installing: true),
      [
        "zsh now reports its folder to Rex, so relative Markdown paths are clickable in new panes (\(file(".zshrc").path)).",
        "bash now reports its folder to Rex, so relative Markdown paths are clickable in new panes"
          + " (\(file(".bashrc").path), \(file(".profile").path)).",
      ])
    XCTAssertEqual(
      shellSetupLines(outcome, installing: false).first,
      "Removed md-viewer's folder reporting for zsh from \(file(".zshrc").path).")
  }

  func testDoctorReportsTheLoginShell() throws {
    XCTAssertEqual(
      setup().doctorLines(rexPath: nil),
      [
        DiagnosticLine(
          level: .fail,
          text:
            "zsh does not report its folder to Rex, so only absolute Markdown paths are clickable; run md-viewer setup")
      ])
    setup().install()
    XCTAssertEqual(
      setup().doctorLines(rexPath: nil),
      [DiagnosticLine(level: .ok, text: "zsh reports its folder to Rex, so relative Markdown paths are clickable")])
    XCTAssertEqual(setup(login: "/bin/tcsh").doctorLines(rexPath: nil).map(\.level), [.info])
    XCTAssertEqual(setup(login: nil).doctorLines(rexPath: nil), [])
  }

  func testDoctorChecksBashsLoginFile() throws {
    try write(".bashrc", ShellDirectoryReporting.bash.text + "\n")
    XCTAssertEqual(setup(login: "/bin/bash").doctorLines(rexPath: nil).map(\.level), [.fail])
    setup(login: "/bin/bash").install()
    XCTAssertEqual(setup(login: "/bin/bash").doctorLines(rexPath: nil).map(\.level), [.ok])
  }

  func testDoctorAsksRexWhetherThisPaneReportsItsFolder() throws {
    let reporting = ScriptedRunner(stdout: "{\"pwd\":\"file://host/tmp\"}") { _, _ in 0 }
    let lines = setup(environment: ["REX_BLOCK": "block:1"], runner: reporting).doctorLines(rexPath: "/usr/bin/rex")
    XCTAssertEqual(lines.last, DiagnosticLine(level: .info, text: "this Rex pane reports its folder"))
    XCTAssertEqual(
      reporting.calls.last?.arguments, ["block", "call", "-b", "block:1", "pwd", "{}", "--autostart=false"])
    let silent = ScriptedRunner(stdout: "{}") { _, _ in 0 }
    XCTAssertEqual(
      setup(environment: ["REX_BLOCK": "block:1"], runner: silent).doctorLines(rexPath: "/usr/bin/rex").last?.text,
      "this Rex pane has not reported its folder; new panes pick up md-viewer setup's changes")
    XCTAssertEqual(
      setup(runner: silent).doctorLines(rexPath: "/usr/bin/rex").count, 1, "outside Rex there is no live check")
  }
}

final class ShellDirectoryReportingLiveTests: XCTestCase {
  private var directory: URL!
  private var home: URL!
  private var target: URL!

  override func setUpWithError() throws {
    directory = testScratchDirectory()
    home = directory.appendingPathComponent("home")
    target = directory.appendingPathComponent("a b/é ☃ #%")
    for url in [home!, target!] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var hostName: String {
    var buffer = [CChar](repeating: 0, count: 256)
    gethostname(&buffer, buffer.count)
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private func expected(_ url: URL) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._~-")
    return "\u{1b}]7;file://\(hostName)\(url.path.addingPercentEncoding(withAllowedCharacters: allowed)!)\u{1b}\\"
  }

  private func runInTerminal(
    _ shell: String, _ arguments: [String], environment: [String: String], terminal: Bool = true,
    input: String? = nil
  ) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: terminal ? "/usr/bin/script" : shell)
    process.arguments = terminal ? ["-q", "/dev/null", shell] + arguments : arguments
    process.environment =
      [
        "HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin", "TERM": "dumb", "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
      ].merging(environment) { $1 }
    process.currentDirectoryURL = directory
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let inputPipe = Pipe()
    process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
    try process.run()
    if let input {
      Thread.sleep(forTimeInterval: 0.5)
      inputPipe.fileHandleForWriting.write(Data(input.utf8))
    }
    defer { try? inputPipe.fileHandleForWriting.close() }
    let pid = process.processIdentifier
    let deadline = DispatchWorkItem { kill(pid, SIGKILL) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    var text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
    if text.hasPrefix("^D\u{8}\u{8}") { text.removeFirst(4) }
    return text
  }

  private func requireShell(_ path: String) throws {
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: path), "\(path) is not installed")
  }

  private func install(login: String) {
    ShellSetup(
      home: home, environment: ["ZDOTDIR": home.path], loginShell: login, locate: { _ in nil }, runner: nil
    ).install()
  }

  func testZshReportsTheFolderOnChangeAndBeforeEachPrompt() throws {
    try requireShell("/bin/zsh")
    install(login: "/bin/zsh")
    let output = try runInTerminal(
      "/bin/zsh", ["-ic", #"cd -- "$TARGET"; for f in $precmd_functions; do $f; done"#],
      environment: ["REX_SESSION": "session:test", "TARGET": target.path])
    XCTAssertEqual(output, expected(target) + expected(target))
  }

  func testZshReportsBeforeThePromptEvenWhenOutputIsRedirected() throws {
    try requireShell("/bin/zsh")
    install(login: "/bin/zsh")
    let output = try runInTerminal(
      "/bin/zsh", ["-ic", #"cd -- "$TARGET"; for f in $precmd_functions; do $f; done"#],
      environment: ["REX_SESSION": "session:test", "TARGET": target.path], terminal: false)
    XCTAssertEqual(output, expected(target), "only the prompt hook writes when stdout is not a terminal")
  }

  func testZshStaysQuietOutsideRexAndInCommandSubstitutions() throws {
    try requireShell("/bin/zsh")
    install(login: "/bin/zsh")
    XCTAssertEqual(
      try runInTerminal(
        "/bin/zsh", ["-ic", #"cd -- "$TARGET"; print -rn done"#], environment: ["TARGET": target.path]),
      "done")
    XCTAssertEqual(
      try runInTerminal(
        "/bin/zsh", ["-ic", #"x=$(cd -- "$TARGET"; print -rn ok); print -rn -- "[$x]""#],
        environment: ["REX_BLOCK": "block:test", "TARGET": target.path]),
      "[ok]")
  }

  func testBashReportsTheFolderFromPromptCommandAndKeepsTheUsersCommand() throws {
    try requireShell("/bin/bash")
    try "PROMPT_COMMAND='printf mine;'\n".write(
      to: home.appendingPathComponent(".bashrc"), atomically: true, encoding: .utf8)
    install(login: "/bin/bash")
    let output = try runInTerminal(
      "/bin/bash", ["-ic", #"cd -- "$TARGET"; eval "$PROMPT_COMMAND"; (exit 3); __md_viewer_osc7; printf "[%s]" $?"#],
      environment: ["REX_SESSION": "session:test", "TARGET": target.path])
    XCTAssertEqual(output, "mine" + expected(target) + expected(target) + "[3]")
  }

  func testBashLoginShellThatSourcesBashrcRegistersTheHookOnce() throws {
    try requireShell("/bin/bash")
    try "[ -f ~/.bashrc ] && . ~/.bashrc\n".write(
      to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
    install(login: "/bin/bash")
    let output = try runInTerminal(
      "/bin/bash", ["-lic", #"printf "[%s]" "$PROMPT_COMMAND""#], environment: ["REX_BLOCK": "block:test"])
    XCTAssertEqual(output, "[__md_viewer_osc7 && :]")
  }

  func testBashFailuresDoNotTripErrTrapsOrErrexitAgainAtThePrompt() throws {
    try requireShell("/bin/bash")
    try "trap 'printf T' ERR\nPS1='[$?]'\n".write(
      to: home.appendingPathComponent(".bashrc"), atomically: true, encoding: .utf8)
    install(login: "/bin/bash")
    let output = try runInTerminal(
      "/bin/bash", ["--noediting", "-i"],
      environment: ["REX_SESSION": "session:test", "BASH_SILENCE_DEPRECATION_WARNING": "1"],
      input: "cd /\nfalse\nset -e\n! true\nprintf alive\nexit 0\n")
    let osc7 = "\u{1b}]7;file://\(hostName)/\u{1b}\\"
    XCTAssertTrue(output.contains("[0]T" + osc7 + "[1]"), "one ERR trap run for false: \(output.debugDescription)")
    XCTAssertTrue(output.contains(osc7 + "[1]alive"), "set -e survives the prompt: \(output.debugDescription)")
  }

  func testBashArrayPromptCommandGetsAnEntry() throws {
    let bash = ["/opt/homebrew/bin/bash", "/usr/local/bin/bash"].first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
    try XCTSkipIf(bash == nil, "bash 5.1 or later is not installed")
    try "PROMPT_COMMAND=('printf one' 'printf two')\n".write(
      to: home.appendingPathComponent(".bashrc"), atomically: true, encoding: .utf8)
    install(login: bash!)
    let output = try runInTerminal(
      bash!, ["-ic", #"cd -- "$TARGET"; for c in "${PROMPT_COMMAND[@]}"; do eval "$c"; done"#],
      environment: ["REX_SESSION": "session:test", "TARGET": target.path])
    XCTAssertEqual(output, "onetwo" + expected(target))
  }

  func testHostileFolderNamesAreDataNotCode() throws {
    let hostile = directory.appendingPathComponent("q\"'$(touch pwned)`touch pwned2`\nx;$HOME")
    try FileManager.default.createDirectory(at: hostile, withIntermediateDirectories: true)
    for shell in ["/bin/zsh", "/bin/bash"] where FileManager.default.isExecutableFile(atPath: shell) {
      install(login: shell)
      let script =
        shell == "/bin/zsh"
        ? #"cd -- "$TARGET"; for f in $precmd_functions; do $f; done"#
        : #"cd -- "$TARGET"; eval "$PROMPT_COMMAND""#
      let output = try runInTerminal(
        shell, ["-ic", script], environment: ["REX_SESSION": "session:test", "TARGET": hostile.path])
      XCTAssertTrue(output.hasSuffix(expected(hostile)), "\(shell): \(output.debugDescription)")
      XCTAssertFalse(output.contains("\n"))
      for name in ["pwned", "pwned2"] {
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostile.appendingPathComponent(name).path), shell)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), shell)
      }
    }
  }

  func testGeneratedSnippetsPassEachShellsSyntaxCheck() throws {
    let checks: [(String, [String], String)] = [
      ("/bin/zsh", ["-fn"], ShellDirectoryReporting.zsh.text),
      ("/bin/bash", ["-n"], ShellDirectoryReporting.bash.text),
      ("/bin/sh", ["-n"], ShellDirectoryReporting.bash.text),
      ("/bin/dash", ["-n"], ShellDirectoryReporting.bash.text),
    ]
    for (shell, flags, text) in checks where FileManager.default.isExecutableFile(atPath: shell) {
      let file = directory.appendingPathComponent(UUID().uuidString)
      try text.write(to: file, atomically: true, encoding: .utf8)
      let result = try ProcessRunner().run(shell, flags + [file.path])
      XCTAssertEqual(result.status, 0, "\(shell): \(String(decoding: result.stderr, as: UTF8.self))")
    }
  }
}

func testScratchDirectory() -> URL {
  let base = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
  return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(UUID().uuidString)
    .resolvingSymlinksInPath()
}

final class ScriptedRunner: ProcessRunning, @unchecked Sendable {
  let stdout: String
  let status: (String, [String]) -> Int32
  var calls: [(executable: String, arguments: [String])] = []

  init(stdout: String = "", status: @escaping (String, [String]) -> Int32) {
    self.stdout = stdout
    self.status = status
  }

  func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> (
    status: Int32, stdout: Data, stderr: Data
  ) {
    calls.append((executable, arguments))
    return (status(executable, arguments), Data(stdout.utf8), Data())
  }
}
