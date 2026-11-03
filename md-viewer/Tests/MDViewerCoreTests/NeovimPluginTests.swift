import Darwin
import XCTest

@testable import MDViewerCore

final class NeovimPluginTests: XCTestCase {
  private let source = NeovimPlugin.source

  private func temporaryPaths() -> SupportPaths {
    SupportPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
  }

  private func assertContains(_ fragments: String..., file: StaticString = #filePath, line: UInt = #line) {
    for fragment in fragments {
      XCTAssertTrue(source.contains(fragment), "missing: \(fragment)", file: file, line: line)
    }
  }

  private func body(of function: String) throws -> String {
    let start = try XCTUnwrap(source.range(of: function))
    let end = try XCTUnwrap(source.range(of: "\nend\n", range: start.upperBound..<source.endIndex))
    return String(source[start.lowerBound..<end.upperBound])
  }

  private func mode(_ url: URL) throws -> Int {
    try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
  }

  func testInstallWritesOnlyWhenContentDiffers() throws {
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.home) }
    XCTAssertTrue(try NeovimPlugin.install(paths))
    XCTAssertEqual(try String(contentsOf: paths.neovimPlugin, encoding: .utf8), source)
    XCTAssertEqual(try mode(paths.neovimPlugin), 0o600)
    XCTAssertEqual(try mode(paths.neovimPlugin.deletingLastPathComponent()), 0o700)

    let before = try FileManager.default.attributesOfItem(atPath: paths.neovimPlugin.path)[.systemFileNumber]
    XCTAssertFalse(try NeovimPlugin.install(paths))
    let after = try FileManager.default.attributesOfItem(atPath: paths.neovimPlugin.path)[.systemFileNumber]
    XCTAssertEqual(before as? Int, after as? Int)

    try Data("old".utf8).write(to: paths.neovimPlugin)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.neovimPlugin.path)
    XCTAssertTrue(try NeovimPlugin.install(paths))
    XCTAssertEqual(try String(contentsOf: paths.neovimPlugin, encoding: .utf8), source)
    XCTAssertEqual(try mode(paths.neovimPlugin), 0o600)
  }

  func testSourceParsesAsLua() throws {
    let luac = "/opt/homebrew/bin/luac"
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: luac), "luac is not installed")
    let paths = temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.home) }
    try NeovimPlugin.install(paths)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: luac)
    process.arguments = ["-p", paths.neovimPlugin.path]
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 0, message)
  }

  func testSourceAvoidsSyntaxNewerThanLuaJIT() {
    for fragment in ["goto ", "//", " & ", " | ", " ~ ", "<<", ">>", "<const>", "<close>"] {
      XCTAssertFalse(source.contains(fragment), fragment)
    }
  }

  func testReadsTheLaunchEnvironment() {
    for name in ["MD_VIEWER_SOCKET", "MD_VIEWER_TOKEN", "MD_VIEWER_CONTROL", "MD_VIEWER_FILES", "MD_VIEWER_BUFFERS"] {
      assertContains("setting('\(name)')")
    }
    assertContains("local uv = vim.uv or vim.loop", "MdViewer = { loaded = true }")
    XCTAssertTrue(source.hasPrefix("if MdViewer and MdViewer.loaded then return end\n"))
    XCTAssertTrue(source.hasSuffix("M.ensure()\nstart_server()\n"))
  }

  func testEnsureIsIdempotentAndSetsUpLoadedBuffers() throws {
    let ensure = try body(of: "function M.ensure()")
    XCTAssertTrue(ensure.contains("api.nvim_create_augroup('md_viewer', { clear = true })"))
    XCTAssertTrue(ensure.contains("{ group = group, callback = callback }"))
    for event in [
      "'VimEnter'", "'VimLeavePre'", "'BufEnter'", "'BufReadPost'", "'BufWritePost'", "'TextChanged'",
      "'TextChangedI'", "'TextChangedP'", "'FileChangedShellPost'", "'CursorMoved'", "'CursorMovedI'",
      "'WinScrolled'", "'BufUnload'", "'BufWipeout'",
    ] {
      XCTAssertTrue(ensure.contains(event), event)
    }
    XCTAssertTrue(
      ensure.contains(
        """
          for _, buf in ipairs(api.nvim_list_bufs()) do
            if api.nvim_buf_is_loaded(buf) and is_markdown(buf) then setup_buffer(buf) end
          end
          write_sidecar()
        """))
    let setup = try body(of: "local function setup_buffer(buf)")
    XCTAssertTrue(setup.contains("if not buffers[buf] then"))
    let watch = try body(of: "watch = function(buf)")
    XCTAssertTrue(watch.contains("if not entry or entry.watch then return end"))
    XCTAssertTrue(watch.contains("uv.new_fs_event()"))
    XCTAssertTrue(watch.contains("restart(entry.watch_timer, WATCH_DEBOUNCE_MS"))
    XCTAssertTrue(watch.contains("pcall(vim.cmd, 'checktime ' .. buf)"))
    assertContains("local WATCH_DEBOUNCE_MS = 200", "timer:start(ms, 0, function() vim.schedule(work) end)")
  }

  func testActsOnlyOnMarkdownBuffersAndSendsRealpaths() throws {
    let markdown = try body(of: "local function is_markdown(buf)")
    XCTAssertTrue(markdown.contains("name:match('%.md$') ~= nil or name:match('%.markdown$') ~= nil"))
    XCTAssertTrue(try body(of: "local function realpath(buf)").contains("uv.fs_realpath(name)"))
    XCTAssertTrue(try body(of: "local function send(kind, buf, extra)").contains("local file = realpath(buf)"))
  }

  func testControlServerListensWithBacklogAndClosesOnLeave() throws {
    let server = try body(of: "local function start_server()")
    XCTAssertTrue(server.contains("server:bind(env.control)"))
    XCTAssertTrue(server.contains("uv.fs_chmod(env.control, FILE_MODE)"))
    XCTAssertTrue(server.contains("server:listen(128,"))
    assertContains("local FILE_MODE = 384", "on('VimLeavePre', shutdown)")
    let shutdown = try body(of: "local function shutdown()")
    XCTAssertTrue(shutdown.contains("close_handle(M.server)"))
  }

  func testFramesInputUntilNewlineOrEOFCappedAt4096Bytes() throws {
    assertContains("local MAX_LINE_BYTES = 4096")
    let accept = try body(of: "local function accept(server)")
    XCTAssertTrue(accept.contains("if data == nil then return finish(table.concat(chunks)) end"))
    XCTAssertTrue(accept.contains("local newline = data:find('\\n', 1, true)"))
    XCTAssertTrue(accept.contains("if size >= MAX_LINE_BYTES then return finish(nil) end"))
    XCTAssertTrue(accept.contains("if line and #line < MAX_LINE_BYTES then handle_line(line) end"))
  }

  func testDecodesWithPcallAndChecksTypes() throws {
    let decode = try body(of: "local function decode_command(line)")
    XCTAssertTrue(decode.contains("pcall(vim.json.decode, line)"))
    XCTAssertTrue(decode.contains("type(command.type) ~= 'string' or type(command.token) ~= 'string'"))
    XCTAssertTrue(decode.contains("type(command.socket) ~= 'string' or type(command.file) ~= 'string'"))
    XCTAssertTrue(decode.contains("if not is_line_number(command.line) then return nil end"))
    let lineNumber = try body(of: "local function is_line_number(value)")
    XCTAssertTrue(
      lineNumber.contains("value ~= vim.NIL and type(value) == 'number' and value >= 1 and value % 1 == 0"))
    let handle = try body(of: "local function handle_line(line)")
    XCTAssertTrue(handle.contains("commands[#commands + 1] = command\n  vim.schedule(run_commands)"))
  }

  func testClampsLines() throws {
    let place = try body(of: "local function place_cursor(win, buf, line)")
    XCTAssertTrue(place.contains("math.max(1, math.min(line, api.nvim_buf_line_count(buf)))"))
    XCTAssertTrue(place.contains("api.nvim_win_call(win, function()"))
  }

  func testLinkAndJumpWorkRunInsidePcall() throws {
    let link = try body(of: "local function run_link(command)")
    XCTAssertTrue(link.contains("local ok, err = pcall(function()"))
    XCTAssertTrue(link.contains("vim.cmd.drop(vim.fn.fnameescape(command.file))"))
    let jump = try body(of: "local function run_jump(command)")
    XCTAssertTrue(jump.contains("pcall(place_cursor, win, buf, command.line)"))
    let run = try body(of: "local function run_commands()")
    XCTAssertTrue(
      run.contains(
        """
            running_command = true
            pcall(command.type == 'link' and run_link or run_jump, command)
            running_command = false
        """))
  }

  func testAFailedLinkIsReportedInNeovim() throws {
    let link = try body(of: "local function run_link(command)")
    XCTAssertTrue(
      link.contains(
        """
          if not ok then
            vim.notify('md-viewer: could not link the preview: ' .. tostring(err), vim.log.levels.WARN)
        """))
  }

  func testCommandsRunInOrderOnlyAfterStartupPromptsAndCommandLineMode() throws {
    let run = try body(of: "local function run_commands()")
    XCTAssertTrue(run.hasPrefix("local function run_commands()\n  if running_command or leaving then return end\n"))
    XCTAssertTrue(
      run.contains(
        """
            if mode == 'c' then
              if awaiting_cmdline then return end
              awaiting_cmdline = true
              api.nvim_create_autocmd('CmdlineLeave', {
                once = true,
                callback = function()
                  awaiting_cmdline = false
                  vim.schedule(run_commands)
                end,
              })
              return
            end
            if waits_for_input(mode) then
              restart(command_timer, PROMPT_RETRY_MS, run_commands)
              return
            end
            local command = table.remove(commands, 1)
        """))
    let waits = try body(of: "local function waits_for_input(mode)")
    XCTAssertTrue(waits.contains("return vim.v.vim_did_enter ~= 1 or mode:sub(1, 1) == 'r'"))
    assertContains("local PROMPT_RETRY_MS = 50")
  }

  func testLinkAdoptsTokenOnlyAfterSuccess() throws {
    let link = try body(of: "local function run_link(command)")
    let failure = try XCTUnwrap(link.range(of: "if not ok then"))
    let unlinked = try XCTUnwrap(link.range(of: "send('unlinked', target)"))
    let adopt = try XCTUnwrap(link.range(of: "link.token = command.token"))
    let snapshot = try XCTUnwrap(link.range(of: "snapshot(target)"))
    XCTAssertLessThan(failure.lowerBound, unlinked.lowerBound)
    XCTAssertLessThan(unlinked.lowerBound, adopt.lowerBound)
    XCTAssertLessThan(adopt.lowerBound, snapshot.lowerBound)
    XCTAssertTrue(link.contains("if link.socket ~= nil and link.socket ~= command.socket then"))
    XCTAssertTrue(link.contains("link.seq = 0"))
    XCTAssertEqual(source.components(separatedBy: "link.token = ").count, 2)
  }

  func testJumpRequiresCurrentTokenAndAWindowShowingTheBuffer() throws {
    let jump = try body(of: "local function run_jump(command)")
    XCTAssertTrue(jump.contains("if command.token ~= link.token or not snapshot_buf then return end"))
    XCTAssertTrue(jump.contains("local win = window_for(buf)\n  if not win then return end"))
    let window = try body(of: "local function window_for(buf)")
    XCTAssertTrue(window.contains("vim.fn.bufwinid(buf)"))
    XCTAssertTrue(window.contains("return nil"))
  }

  func testSendsExitSynchronously() throws {
    let exit = try body(of: "local function send_exit()")
    XCTAssertTrue(exit.contains("vim.fn.sockconnect('pipe', link.socket, { rpc = false })"))
    XCTAssertTrue(exit.contains("vim.fn.chansend(channel, line)"))
    XCTAssertTrue(exit.contains("vim.fn.chanclose(channel)"))
    let shutdown = try body(of: "local function shutdown()")
    XCTAssertTrue(shutdown.hasPrefix("local function shutdown()\n  send_exit()\n"))
    XCTAssertTrue(
      shutdown.contains("leaving = true\n  commands = {}\n  command_timer:stop()\n  close_handle(command_timer)\n"))
    XCTAssertTrue(shutdown.contains("os.remove(env.files)"))
    XCTAssertTrue(shutdown.contains("for buf in pairs(buffer_files) do remove_buffer_file(buf) end"))
  }

  func testWritesSidecarRegardlessOfLinkState() throws {
    let ensure = try body(of: "function M.ensure()")
    XCTAssertTrue(
      ensure.contains(
        """
          on('BufEnter', function(args)
            if not is_markdown(args.buf) then return end
            setup_buffer(args.buf)
            write_sidecar()
        """))
    XCTAssertTrue(
      ensure.contains(
        """
          on({ 'BufReadPost', 'BufWritePost' }, function(args)
            if not is_markdown(args.buf) then return end
            setup_buffer(args.buf)
            write_sidecar()
        """))
    let sidecar = try body(of: "local function write_sidecar(exclude)")
    XCTAssertFalse(sidecar.contains("linked()"))
    XCTAssertTrue(sidecar.contains("write_atomic(env.files, table.concat(lines))"))
    let atomic = try body(of: "local function write_atomic(path, content)")
    XCTAssertTrue(atomic.contains("uv.fs_open(temp, 'wx', FILE_MODE)"))
    XCTAssertTrue(atomic.contains("uv.fs_rename(temp, path)"))
  }

  func testSnapshotOrderAndVimEnter() throws {
    let snapshot = try body(of: "local function snapshot(buf)")
    XCTAssertTrue(
      snapshot.contains("  send('follow', buf)\n  send_text(buf)\n  send_cursor(buf)\n"))
    assertContains("on('VimEnter', function() snapshot(api.nvim_get_current_buf()) end)")
    let text = try body(of: "local function send_text(buf)")
    XCTAssertTrue(text.contains("if vim.bo[buf].modified then"))
    XCTAssertTrue(text.contains("send('buffer', buf, { text = path })"))
    XCTAssertTrue(text.contains("remove_buffer_file(buf)\n    send('clean', buf)"))
    XCTAssertTrue(
      try body(of: "local function buffer_file(buf)").contains(
        "env.buffers .. '/' .. uv.os_getpid() .. '-' .. buf .. '.md'"))
  }

  func testMessagesCarrySeqPerTokenAndStopAfterAFailedConnect() throws {
    let message = try body(of: "local function message(kind, file, extra)")
    XCTAssertTrue(message.contains("link.seq = link.seq + 1"))
    XCTAssertTrue(message.contains("{ type = kind, token = link.token, seq = link.seq, file = file }"))
    let pump = try body(of: "local function pump()")
    XCTAssertTrue(pump.contains("if not ok and item.generation == link.generation then\n        link.failed = true"))
    XCTAssertTrue(try body(of: "local function linked()").contains("not link.failed"))
    assertContains(
      "local CURSOR_DEBOUNCE_MS = 50", "local TEXT_DEBOUNCE_MS = 150",
      "restart(cursor_timer, CURSOR_DEBOUNCE_MS,", "restart(entry.text_timer, TEXT_DEBOUNCE_MS,")
  }

  func testLinkLineKeepsPathsWithSpacePercentAndHash() throws {
    let file = "/tmp/notes dir/50% #1.md"
    let command = EditorControlCommand.link(socket: "/tmp/v/a b.sock", token: "t0", file: file, line: 3)
    let line = command.wireLine
    XCTAssertFalse(line.contains("\n"))
    XCTAssertTrue(line.contains(#""file":"/tmp/notes dir/50% #1.md""#))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    XCTAssertEqual(object["file"] as? String, file)
    XCTAssertEqual(object["type"] as? String, "link")
    XCTAssertEqual(EditorControlCommand.parse(line), command)
  }

  func testControlClientNeverUnlinksTheControlSocket() throws {
    let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("mdv-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = directory.appendingPathComponent("c.sock")
    var address = try XCTUnwrap(socketAddress(path: control.path))
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    Darwin.close(descriptor)
    let link = EditorControlCommand.link(socket: "/tmp/v.sock", token: "t", file: "/tmp/a b.md", line: 1)
    XCTAssertFalse(ViewerSocketClient.send(link, to: control))
    XCTAssertFalse(ViewerSocketClient.send(.jump(token: "t", line: 1), to: control))
    XCTAssertTrue(FileManager.default.fileExists(atPath: control.path))
  }
}
