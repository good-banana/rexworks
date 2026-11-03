import Foundation

public enum NeovimPlugin {
  @discardableResult
  public static func install(_ paths: SupportPaths) throws -> Bool {
    let file = paths.neovimPlugin
    let content = Data(source.utf8)
    if (try? Data(contentsOf: file)) == content { return false }
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try content.write(to: file, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return true
  }

  public static let source = #"""
    if MdViewer and MdViewer.loaded then return end

    local uv = vim.uv or vim.loop
    local api = vim.api

    MdViewer = { loaded = true }
    local M = MdViewer

    local MAX_LINE_BYTES = 4096
    local CURSOR_DEBOUNCE_MS = 50
    local TEXT_DEBOUNCE_MS = 150
    local WATCH_DEBOUNCE_MS = 200
    local PROMPT_RETRY_MS = 50
    local FILE_MODE = 384
    local DIRECTORY_MODE = 448

    local function setting(name)
      local value = os.getenv(name)
      if value == nil or value == '' then return nil end
      return value
    end

    local env = {
      socket = setting('MD_VIEWER_SOCKET'),
      token = setting('MD_VIEWER_TOKEN'),
      control = setting('MD_VIEWER_CONTROL'),
      files = setting('MD_VIEWER_FILES'),
      buffers = setting('MD_VIEWER_BUFFERS'),
    }

    local link = {
      socket = env.token and env.socket,
      token = env.socket and env.token,
      seq = 0,
      generation = 0,
      failed = false,
    }

    local buffers = {}
    local buffer_files = {}
    local queue = {}
    local sending = false
    local linking = false
    local leaving = false
    local snapshot_buf = nil
    local last_file = nil
    local temp_counter = 0
    local cursor_timer = uv.new_timer()
    local commands = {}
    local command_timer = uv.new_timer()
    local running_command = false
    local awaiting_cmdline = false

    local function restart(timer, ms, work)
      timer:stop()
      timer:start(ms, 0, function() vim.schedule(work) end)
    end

    local function close_handle(handle)
      if handle and not handle:is_closing() then handle:close() end
    end

    local function is_markdown(buf)
      if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then return false end
      local name = api.nvim_buf_get_name(buf):lower()
      return name:match('%.md$') ~= nil or name:match('%.markdown$') ~= nil
    end

    local function realpath(buf)
      local name = api.nvim_buf_get_name(buf)
      if name == '' then return nil end
      return uv.fs_realpath(name)
    end

    local function write_atomic(path, content)
      temp_counter = temp_counter + 1
      local temp = path .. '.' .. uv.os_getpid() .. '.' .. temp_counter .. '.tmp'
      local fd = uv.fs_open(temp, 'wx', FILE_MODE)
      if not fd then return false end
      local written = uv.fs_write(fd, content, 0)
      uv.fs_close(fd)
      if not written or not uv.fs_rename(temp, path) then
        uv.fs_unlink(temp)
        return false
      end
      return true
    end

    local function write_sidecar(exclude)
      if leaving or not env.files then return end
      local seen, lines = {}, {}
      for _, buf in ipairs(api.nvim_list_bufs()) do
        if buf ~= exclude and api.nvim_buf_is_loaded(buf) and is_markdown(buf) then
          local path = realpath(buf)
          if path and not seen[path] then
            seen[path] = true
            lines[#lines + 1] = path .. '\n'
          end
        end
      end
      write_atomic(env.files, table.concat(lines))
    end

    local function deliver(path, line, done)
      local pipe = uv.new_pipe(false)
      local finished = false
      local function finish(ok)
        if finished then return end
        finished = true
        close_handle(pipe)
        done(ok)
      end
      local ok, request = pcall(pipe.connect, pipe, path, function(err)
        if err then return finish(false) end
        local queued = pipe:write(line .. '\n', function(write_err) finish(not write_err) end)
        if not queued then finish(false) end
      end)
      if not ok or not request then finish(false) end
    end

    local function pump()
      if sending then return end
      local item = table.remove(queue, 1)
      if not item then return end
      sending = true
      deliver(item.socket, item.line, function(ok)
        vim.schedule(function()
          sending = false
          if not ok and item.generation == link.generation then
            link.failed = true
            local kept = {}
            for _, pending in ipairs(queue) do
              if pending.generation ~= item.generation then kept[#kept + 1] = pending end
            end
            queue = kept
          end
          pump()
        end)
      end)
    end

    local function linked()
      return link.socket ~= nil and link.token ~= nil and not link.failed
    end

    local function message(kind, file, extra)
      link.seq = link.seq + 1
      local fields = { type = kind, token = link.token, seq = link.seq, file = file }
      for key, value in pairs(extra or {}) do fields[key] = value end
      return vim.json.encode(fields)
    end

    local function send(kind, buf, extra)
      if not linked() then return end
      local file = realpath(buf)
      if not file then return end
      last_file = file
      queue[#queue + 1] = { socket = link.socket, generation = link.generation, line = message(kind, file, extra) }
      pump()
    end

    local function window_for(buf)
      local current = api.nvim_get_current_win()
      if api.nvim_win_get_buf(current) == buf then return current end
      local win = vim.fn.bufwinid(buf)
      if win ~= -1 then return win end
      return nil
    end

    local function send_cursor(buf)
      local win = window_for(buf)
      if not win then return end
      send('cursor', buf, {
        line = api.nvim_win_get_cursor(win)[1],
        top = vim.fn.line('w0', win),
        height = api.nvim_win_get_height(win),
      })
    end

    local function buffer_file(buf)
      return env.buffers .. '/' .. uv.os_getpid() .. '-' .. buf .. '.md'
    end

    local function remove_buffer_file(buf)
      local path = buffer_files[buf]
      if not path then return end
      buffer_files[buf] = nil
      uv.fs_unlink(path)
    end

    local function write_buffer_file(buf)
      if not env.buffers then return nil end
      uv.fs_mkdir(env.buffers, DIRECTORY_MODE)
      local path = buffer_file(buf)
      local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
      if not write_atomic(path, table.concat(lines, '\n') .. '\n') then return nil end
      buffer_files[buf] = path
      return path
    end

    local function send_text(buf)
      if not linked() or not api.nvim_buf_is_valid(buf) then return end
      if vim.bo[buf].modified then
        local path = write_buffer_file(buf)
        if path then send('buffer', buf, { text = path }) end
      else
        remove_buffer_file(buf)
        send('clean', buf)
      end
    end

    local function snapshot(buf)
      if not is_markdown(buf) then return end
      snapshot_buf = buf
      send('follow', buf)
      send_text(buf)
      send_cursor(buf)
    end

    local function schedule_text(buf)
      local entry = buffers[buf]
      if not entry then return end
      restart(entry.text_timer, TEXT_DEBOUNCE_MS, function() send_text(buf) end)
    end

    local function schedule_cursor()
      restart(cursor_timer, CURSOR_DEBOUNCE_MS, function()
        local buf = api.nvim_get_current_buf()
        if is_markdown(buf) then send_cursor(buf) end
      end)
    end

    local watch

    local function rewatch(buf)
      local entry = buffers[buf]
      if not entry then return end
      if entry.watch then
        entry.watch:stop()
        close_handle(entry.watch)
        entry.watch = nil
      end
      watch(buf)
    end

    watch = function(buf)
      local entry = buffers[buf]
      if not entry or entry.watch then return end
      local path = realpath(buf)
      if not path then return end
      local handle = uv.new_fs_event()
      if not handle then return end
      local started = handle:start(path, {}, function()
        if buffers[buf] ~= entry then return end
        restart(entry.watch_timer, WATCH_DEBOUNCE_MS, function()
          if buffers[buf] ~= entry or not api.nvim_buf_is_loaded(buf) then return end
          pcall(vim.cmd, 'checktime ' .. buf)
          rewatch(buf)
        end)
      end)
      if not started then
        close_handle(handle)
        return
      end
      entry.watch = handle
    end

    local function setup_buffer(buf)
      if not buffers[buf] then
        buffers[buf] = { text_timer = uv.new_timer(), watch_timer = uv.new_timer() }
      end
      watch(buf)
    end

    local function teardown_buffer(buf)
      local entry = buffers[buf]
      if not entry then return end
      buffers[buf] = nil
      if entry.watch then entry.watch:stop() end
      close_handle(entry.watch)
      close_handle(entry.text_timer)
      close_handle(entry.watch_timer)
      remove_buffer_file(buf)
    end

    local function place_cursor(win, buf, line)
      local target = math.max(1, math.min(line, api.nvim_buf_line_count(buf)))
      api.nvim_win_set_cursor(win, { target, 0 })
      api.nvim_win_call(win, function()
        local half = math.floor(api.nvim_win_get_height(win) / 2)
        vim.fn.winrestview({ topline = math.max(1, target - half) })
      end)
    end

    local function run_link(command)
      local previous = api.nvim_get_current_buf()
      local target
      linking = true
      local ok, err = pcall(function()
        vim.cmd.drop(vim.fn.fnameescape(command.file))
        target = api.nvim_get_current_buf()
        place_cursor(api.nvim_get_current_win(), target, command.line)
      end)
      linking = false
      if not ok then
        vim.notify('md-viewer: could not link the preview: ' .. tostring(err), vim.log.levels.WARN)
        local current = api.nvim_get_current_buf()
        if current ~= previous then snapshot(current) end
        return
      end
      if link.socket ~= nil and link.socket ~= command.socket then
        send('unlinked', target)
      end
      link.socket = command.socket
      link.token = command.token
      link.seq = 0
      link.failed = false
      link.generation = link.generation + 1
      snapshot(target)
    end

    local function run_jump(command)
      if command.token ~= link.token or not snapshot_buf then return end
      local buf = snapshot_buf
      if not api.nvim_buf_is_loaded(buf) then return end
      local win = window_for(buf)
      if not win then return end
      pcall(place_cursor, win, buf, command.line)
    end

    local function waits_for_input(mode)
      return vim.v.vim_did_enter ~= 1 or mode:sub(1, 1) == 'r'
    end

    local function run_commands()
      if running_command or leaving then return end
      while commands[1] do
        local mode = api.nvim_get_mode().mode
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
        running_command = true
        pcall(command.type == 'link' and run_link or run_jump, command)
        running_command = false
      end
    end

    local function is_line_number(value)
      return value ~= vim.NIL and type(value) == 'number' and value >= 1 and value % 1 == 0
    end

    local function decode_command(line)
      local ok, command = pcall(vim.json.decode, line)
      if not ok or type(command) ~= 'table' then return nil end
      if type(command.type) ~= 'string' or type(command.token) ~= 'string' then return nil end
      if not is_line_number(command.line) then return nil end
      if command.type == 'link' then
        if type(command.socket) ~= 'string' or type(command.file) ~= 'string' then return nil end
        return command
      end
      if command.type == 'jump' then return command end
      return nil
    end

    local function handle_line(line)
      local command = decode_command(line)
      if not command then return end
      commands[#commands + 1] = command
      vim.schedule(run_commands)
    end

    local function accept(server)
      local client = uv.new_pipe(false)
      local ok, accepted = pcall(server.accept, server, client)
      if not ok or not accepted then
        close_handle(client)
        return
      end
      local chunks, size, done = {}, 0, false
      local function finish(line)
        if done then return end
        done = true
        pcall(client.read_stop, client)
        close_handle(client)
        if line and #line < MAX_LINE_BYTES then handle_line(line) end
      end
      local reading = client:read_start(function(err, data)
        if err then return finish(nil) end
        if data == nil then return finish(table.concat(chunks)) end
        local newline = data:find('\n', 1, true)
        if newline then
          chunks[#chunks + 1] = data:sub(1, newline - 1)
          return finish(table.concat(chunks))
        end
        size = size + #data
        if size >= MAX_LINE_BYTES then return finish(nil) end
        chunks[#chunks + 1] = data
      end)
      if not reading then finish(nil) end
    end

    local function start_server()
      if M.server or not env.control then return end
      local server = uv.new_pipe(false)
      local ok = pcall(function()
        assert(server:bind(env.control))
        uv.fs_chmod(env.control, FILE_MODE)
        assert(server:listen(128, function(err)
          if not err then accept(server) end
        end))
      end)
      if not ok then
        close_handle(server)
        return
      end
      M.server = server
    end

    local function send_exit()
      if not linked() or not last_file then return end
      local line = message('exit', last_file) .. '\n'
      pcall(function()
        local channel = vim.fn.sockconnect('pipe', link.socket, { rpc = false })
        vim.fn.chansend(channel, line)
        vim.fn.chanclose(channel)
      end)
    end

    local function shutdown()
      send_exit()
      leaving = true
      commands = {}
      command_timer:stop()
      close_handle(command_timer)
      if M.server then
        close_handle(M.server)
        M.server = nil
      end
      if env.files then os.remove(env.files) end
      for buf in pairs(buffer_files) do remove_buffer_file(buf) end
    end

    function M.ensure()
      local group = api.nvim_create_augroup('md_viewer', { clear = true })
      local function on(events, callback)
        api.nvim_create_autocmd(events, { group = group, callback = callback })
      end

      on('VimEnter', function() snapshot(api.nvim_get_current_buf()) end)
      on('VimLeavePre', shutdown)
      on('BufEnter', function(args)
        if not is_markdown(args.buf) then return end
        setup_buffer(args.buf)
        write_sidecar()
        if not linking then snapshot(args.buf) end
      end)
      on({ 'BufReadPost', 'BufWritePost' }, function(args)
        if not is_markdown(args.buf) then return end
        setup_buffer(args.buf)
        write_sidecar()
        schedule_text(args.buf)
      end)
      on({ 'TextChanged', 'TextChangedI', 'TextChangedP', 'FileChangedShellPost' }, function(args)
        if is_markdown(args.buf) then schedule_text(args.buf) end
      end)
      on({ 'CursorMoved', 'CursorMovedI', 'WinScrolled' }, schedule_cursor)
      on({ 'BufUnload', 'BufWipeout' }, function(args)
        teardown_buffer(args.buf)
        write_sidecar(args.buf)
      end)

      for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) and is_markdown(buf) then setup_buffer(buf) end
      end
      write_sidecar()
    end

    M.ensure()
    start_server()

    """#
}
