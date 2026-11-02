import Foundation

public enum RexFindBinding {
  public static let actionName = "md_viewer_find"
  public static let beginMarker = "-- >>> md-viewer: Cmd-F binding (managed by md-viewer setup; edits are replaced) >>>"
  public static let endMarker = "-- <<< md-viewer <<<"

  public static let lua = """
    \(beginMarker)
    local function md_viewer_pane(block)
      if block == nil then return false end
      local terminal = "com.superlogical.terminal"
      local process = rex.block.call(terminal, "process", { block_id = block })
      if process ~= nil then
        return process.foreground ~= nil and process.foreground.name == "md-viewer"
      end
      local listed = rex.session.list_blocks{}
      for _, entry in ipairs((listed or {}).blocks or {}) do
        if entry.block_id == block then return entry.label == "md-viewer" end
      end
      return false
    end

    rex.action{
      name = "\(actionName)",
      title = "Find (md-viewer aware)",
      description = "Opens md-viewer's find in an md-viewer pane and Rex's Find everywhere else.",
      run = function(ctx, args)
        if md_viewer_pane(ctx.block_id) then
          local _, err = rex.block.call(
            "com.superlogical.terminal", "write", { block_id = ctx.block_id, data = "\\27[102;9u" })
          if err == nil then return { target = "md-viewer" } end
        end
        rex.client.queue("client.find.open")
        return { target = "rex" }
      end,
    }

    rex.bind("cmd+f", "\(actionName)")
    \(endMarker)
    """

  public static func configFile(environment: [String: String], home: URL) -> URL {
    if let path = environment["REX_CONFIG"], !path.isEmpty {
      return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    if let base = environment["XDG_CONFIG_HOME"], !base.isEmpty {
      return URL(fileURLWithPath: base).appendingPathComponent("rex/init.lua")
    }
    return home.appendingPathComponent(".config/rex/init.lua")
  }

  public enum EditError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case notUTF8
    case unterminatedBlock
    case checkFailed(String)

    public var description: String {
      switch self {
      case .unreadable(let reason): "it could not be read (\(reason))"
      case .notUTF8: "it is not valid UTF-8"
      case .unterminatedBlock: "it has an md-viewer begin marker without the end marker"
      case .checkFailed(let output): "the edited config did not pass rex config check: \(output)"
      }
    }
  }

  public static func removing(from text: String) throws -> String {
    var lines = text.components(separatedBy: "\n")
    while let start = lines.firstIndex(of: beginMarker) {
      guard let end = lines[start...].firstIndex(of: endMarker) else { throw EditError.unterminatedBlock }
      lines.removeSubrange(start...end)
      if start > 0, start <= lines.count, lines[start - 1].isEmpty, start == lines.count || lines[start].isEmpty {
        lines.remove(at: start - 1)
      }
    }
    return lines.joined(separator: "\n")
  }

  public static func installing(into text: String) throws -> String {
    var kept = try removing(from: text)
    while kept.hasSuffix("\n\n") { kept.removeLast() }
    if kept.isEmpty { return lua + "\n" }
    return kept + (kept.hasSuffix("\n") ? "\n" : "\n\n") + lua + "\n"
  }

  public static func read(_ url: URL) throws -> String? {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch {
      throw EditError.unreadable(error.localizedDescription)
    }
    guard let text = String(data: data, encoding: .utf8) else { throw EditError.notUTF8 }
    return text
  }

  public struct Editor {
    public var runner: ProcessRunning?
    public var rexPath: String?

    public init(runner: ProcessRunning? = ProcessRunner(timeout: 10), rexPath: String?) {
      self.runner = runner
      self.rexPath = rexPath
    }

    @discardableResult
    public func install(at configured: URL) throws -> Bool {
      try edit(configured) { try RexFindBinding.installing(into: $0 ?? "") }
    }

    @discardableResult
    public func remove(at configured: URL) throws -> Bool {
      try edit(configured) { existing in
        guard let existing else { return nil }
        return try RexFindBinding.removing(from: existing)
      }
    }

    private func edit(_ configured: URL, _ change: (String?) throws -> String?) throws -> Bool {
      let url = configured.resolvingSymlinksInPath()
      let existing = try RexFindBinding.read(url)
      guard let updated = try change(existing), updated != existing else { return false }
      let directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let candidate = directory.appendingPathComponent(".\(url.lastPathComponent).md-viewer-\(UUID().uuidString)")
      try Data(updated.utf8).write(to: candidate, options: .withoutOverwriting)
      do {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o644
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: candidate.path)
        try check(candidate)
        guard rename(candidate.path, url.path) == 0 else {
          throw EditError.unreadable(String(cString: strerror(errno)))
        }
      } catch {
        try? FileManager.default.removeItem(at: candidate)
        throw error
      }
      return true
    }

    private func check(_ candidate: URL) throws {
      guard let runner, let rexPath else { return }
      let result = try runner.run(rexPath, ["config", "check", candidate.path, "--autostart=false"], timeout: 10)
      guard result.status == 0 else {
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
          .split(separator: "\n").filter { $0.lowercased().contains("error") }.joined(separator: "; ")
        throw EditError.checkFailed(output.isEmpty ? "exit status \(result.status)" : output)
      }
    }
  }
}
