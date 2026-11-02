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
      if process ~= nil and process.foreground ~= nil and process.foreground.name == "md-viewer" then
        return true
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

  public static func removing(from text: String) -> String {
    var lines = text.components(separatedBy: "\n")
    while let start = lines.firstIndex(of: beginMarker) {
      let end = lines[start...].firstIndex(of: endMarker) ?? lines.count - 1
      lines.removeSubrange(start...end)
      if start > 0, start <= lines.count, lines[start - 1].isEmpty, start == lines.count || lines[start].isEmpty {
        lines.remove(at: start - 1)
      }
    }
    return lines.joined(separator: "\n")
  }

  public static func installing(into text: String) -> String {
    var kept = removing(from: text)
    while kept.hasSuffix("\n\n") { kept.removeLast() }
    if kept.isEmpty { return lua + "\n" }
    return kept + (kept.hasSuffix("\n") ? "\n" : "\n\n") + lua + "\n"
  }

  @discardableResult
  public static func install(at configured: URL) throws -> Bool {
    let url = configured.resolvingSymlinksInPath()
    let existing = try? String(contentsOf: url, encoding: .utf8)
    let updated = installing(into: existing ?? "")
    guard updated != existing else { return false }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try updated.write(to: url, atomically: false, encoding: .utf8)
    return true
  }

  @discardableResult
  public static func remove(at configured: URL) throws -> Bool {
    let url = configured.resolvingSymlinksInPath()
    guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return false }
    let updated = removing(from: existing)
    guard updated != existing else { return false }
    try updated.write(to: url, atomically: false, encoding: .utf8)
    return true
  }
}
