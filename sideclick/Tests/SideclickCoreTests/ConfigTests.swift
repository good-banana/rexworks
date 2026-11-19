import Foundation
import SideclickCore
import Testing

struct ConfigTests {
  func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  @Test func roundTripsWithPrivatePermissions() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = SupportPaths(home: home)
    let config = Config(
      rexPath: "/opt/rex", browserPath: "/opt/tb", previousHandlers: ["https": "com.brave.browser"])

    try ConfigStore.save(config, paths)

    #expect(try ConfigStore.load(paths) == config)
    let fileMode = try FileManager.default.attributesOfItem(atPath: paths.configFile.path)[.posixPermissions] as? Int
    let folderMode = try FileManager.default.attributesOfItem(atPath: paths.root.path)[.posixPermissions] as? Int
    #expect(fileMode == 0o600)
    #expect(folderMode == 0o700)
  }

  @Test func loadsNothingWhenThereIsNoConfig() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(try ConfigStore.load(SupportPaths(home: home)) == nil)
  }

  @Test func findsExecutablesOnThePath() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let tool = home.appendingPathComponent("tool")
    FileManager.default.createFile(atPath: tool.path, contents: Data(), attributes: [.posixPermissions: 0o755])
    let plain = home.appendingPathComponent("plain")
    FileManager.default.createFile(atPath: plain.path, contents: Data(), attributes: [.posixPermissions: 0o644])

    #expect(findExecutable("tool", path: "/nonexistent::\(home.path)") == tool.path)
    #expect(findExecutable("plain", path: home.path) == nil)
    #expect(findExecutable("tool", path: nil) == nil)
  }
}

struct LaunchServicesTests {
  @Test func recordsPreviousHandlersButNotItself() {
    let recorded = recordPreviousHandlers(
      existing: ["http": "com.brave.browser"],
      current: ["http": routerBundleID, "https": "com.brave.browser"])
    #expect(recorded == ["http": "com.brave.browser", "https": "com.brave.browser"])
  }

  @Test func keepsTheRecordedHandlerWhenNoneIsCurrent() {
    let recorded = recordPreviousHandlers(existing: ["https": "com.brave.browser"], current: ["https": nil])
    #expect(recorded == ["https": "com.brave.browser"])
  }

  @Test func restoresRecordedBrowsersAndFallsBackToSafari() {
    let plan = restorePlan(previous: ["http": "com.brave.browser", "https": "com.gone"]) { $0 != "com.gone" }
    #expect(
      plan == [
        RestoreStep(scheme: "http", bundleID: "com.brave.browser", missingPrevious: nil),
        RestoreStep(scheme: "https", bundleID: safariBundleID, missingPrevious: "com.gone"),
      ])
  }

  @Test func restoresSafariWhenNothingWasRecorded() {
    #expect(restorePlan(previous: [:]) { _ in true }.map(\.bundleID) == [safariBundleID, safariBundleID])
  }
}

struct ProcessRunnerTests {
  @Test func capturesStatusAndOutput() throws {
    let result = try ProcessRunner().run("/bin/sh", ["-c", "printf out; printf err >&2; exit 3"])
    #expect(result.status == 3)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "out")
    #expect(result.stderrText == "err")
  }

  @Test func readsOutputLargerThanThePipeBuffer() throws {
    let result = try ProcessRunner().run("/bin/sh", ["-c", "head -c 300000 /dev/zero; head -c 300000 /dev/zero >&2"])
    #expect(result.status == 0)
    #expect(result.stdout.count == 300_000)
    #expect(result.stderr.count == 300_000)
  }

  @Test func stopsCommandsThatRunPastTheTimeout() throws {
    let started = Date()
    let result = try ProcessRunner(timeout: 0.5).run("/bin/sleep", ["10"])
    #expect(result.status != 0)
    #expect(Date().timeIntervalSince(started) < 5)
  }

  @Test func killsCommandsThatIgnoreTermination() throws {
    let started = Date()
    let result = try ProcessRunner(timeout: 0.3, killGrace: 0.3).run(
      "/bin/sh", ["-c", "trap '' TERM; sleep 10 & wait; sleep 10"])
    #expect(result.status != 0)
    #expect(Date().timeIntervalSince(started) < 5)
  }
}
