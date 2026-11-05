import Foundation

public enum RexFindBinding {
  public static let actionName = "md_viewer_find"
  public static let beginMarker = "-- >>> md-viewer: Cmd-F binding (managed by md-viewer setup; edits are replaced) >>>"
  public static let endMarker = "-- <<< md-viewer <<<"

  public static let lua = block.text

  static let luaBody = """
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

  public typealias EditError = ManagedFileError

  static let block = ManagedBlock(beginMarker: beginMarker, endMarker: endMarker, body: luaBody)

  public static func removing(from text: String) throws -> String {
    try block.removing(from: text)
  }

  public static func installing(into text: String) throws -> String {
    try block.installing(into: text)
  }

  public static func read(_ url: URL) throws -> String? {
    try ManagedFile.read(url)
  }

  public struct Editor {
    public var runner: ProcessRunning?
    public var rexPath: String?
    public var synchronize: (URL) throws -> Void

    public init(
      runner: ProcessRunning? = ProcessRunner(timeout: 10), rexPath: String?,
      synchronize: @escaping (URL) throws -> Void = Editor.fsync
    ) {
      self.runner = runner
      self.rexPath = rexPath
      self.synchronize = synchronize
    }

    public static func fsync(_ url: URL) throws {
      try ManagedFile.fsync(url)
    }

    @discardableResult
    public func install(at configured: URL) throws -> Bool {
      try edit(configured, checksCandidate: { _ in true }, change: { try RexFindBinding.installing(into: $0 ?? "") })
    }

    @discardableResult
    public func remove(at configured: URL) throws -> Bool {
      try edit(
        configured, checksCandidate: { (try? check($0)) != nil },
        change: { existing in
          guard let existing else { return nil }
          return try RexFindBinding.removing(from: existing)
        })
    }

    private func edit(
      _ configured: URL, checksCandidate: (URL) -> Bool, change: (String?) throws -> String?
    ) throws -> Bool {
      try ManagedFile.edit(
        configured, synchronize: synchronize, checksCandidate: checksCandidate, check: check, change: change)
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

public func uninstallThenRemoveFindBinding(
  restore: () async throws -> [String], removeFindBinding: () -> Void
) async rethrows -> [String] {
  let failures = try await restore()
  if failures.isEmpty { removeFindBinding() }
  return failures
}
