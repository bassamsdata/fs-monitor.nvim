---@module "fs-monitor.types"
--- OpenCode adapter for fs-monitor.nvim
--- Tracks file changes made by OpenCode via:
---   1. JS plugin (installed in .opencode/plugins/) → Neovim RPC
---   2. SSE event streaming (when opencode serve is running)
---
--- The JS plugin subscribes to file.edited, session.idle, and tool.execute.after
--- events and calls _on_file_changed / _on_session_complete via nvim --remote-expr.

local uv = vim.uv
local log = require("fs-monitor.log")
local fmt = string.format

--- File-based debug log
---@param msg string
local function debug_log(msg)
  local ts = os.date("%H:%M:%S")
  local line = fmt("[%s][opencode] %s\n", ts, msg)
  local fd = io.open("/tmp/fs-monitor-debug.log", "a")
  if fd then
    fd:write(line)
    fd:close()
  end
  log:debug(msg)
end

local M = {}

---@type string|nil Active session ID
M._session_id = nil

---@type number Response cycle counter
M._cycle = 0

---@type table|nil Background curl process for SSE
M._sse_handle = nil

---@type number|nil The port of the connected OpenCode server
M._port = nil

---@type string The integration mode: "sse" or "plugin"
M._mode = "plugin"

-- ============================================================================
-- PORT DISCOVERY (for SSE mode)
-- ============================================================================

---Discover running OpenCode server instances by probing known ports
---@param callback fun(instances: { port: number, version?: string }[])
local function discover_instances(callback)
  local ports_to_check = { 4096, 4097, 4098, 4099, 4100 }
  local instances = {}
  local remaining = #ports_to_check

  for _, port in ipairs(ports_to_check) do
    vim.system(
      { "curl", "-sf", "--max-time", "1", fmt("http://127.0.0.1:%d/global/health", port) },
      { text = true },
      function(result)
        vim.schedule(function()
          if result.code == 0 and result.stdout then
            local ok, data = pcall(vim.json.decode, result.stdout)
            if ok and data and data.healthy then table.insert(instances, { port = port, version = data.version }) end
          end
          remaining = remaining - 1
          if remaining == 0 then callback(instances) end
        end)
      end
    )
  end
end

-- ============================================================================
-- SSE EVENT STREAM (Mode: "sse")
-- ============================================================================

---Parse an SSE data line
---@param line string
---@return table|nil
local function parse_sse_event(line)
  if not line or line == "" then return nil end
  local json_str = line:match("^data:%s*(.+)$")
  if not json_str then return nil end
  local ok, event = pcall(vim.json.decode, json_str)
  if not ok or not event then return nil end
  return event
end

---Start the SSE event stream
---@param port number
---@param on_event fun(event: table)
---@return table|nil handle
local function start_sse_stream(port, on_event)
  local buffer = ""
  local handle = vim.system({ "curl", "-sN", fmt("http://127.0.0.1:%d/event", port) }, {
    text = true,
    stdout = function(_, data)
      if not data then return end
      buffer = buffer .. data
      while true do
        local newline_pos = buffer:find("\n")
        if not newline_pos then break end
        local line = buffer:sub(1, newline_pos - 1)
        buffer = buffer:sub(newline_pos + 1)
        if line ~= "" then
          local event = parse_sse_event(line)
          if event then
            vim.schedule(function()
              on_event(event)
            end)
          end
        end
      end
    end,
  })
  return handle
end

-- ============================================================================
-- PLUGIN INSTALLATION (Mode: "plugin")
-- ============================================================================

---Get the path to the JS plugin shipped with this Neovim plugin
---@return string
local function get_plugin_source_path()
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(source), "..", "..", ".."))
  return vim.fs.joinpath(plugin_root, "scripts", "fs-monitor-opencode-plugin.js")
end

--- Async read entire file via uv
---@param path string
---@param callback fun(data: string|nil, err: string|nil)
local function read_file_async(path, callback)
  uv.fs_open(path, "r", 438, function(err_open, fd)
    if err_open or not fd then return callback(nil, err_open or "open failed") end
    uv.fs_fstat(fd, function(err_stat, stat)
      if err_stat or not stat then
        uv.fs_close(fd, function() end)
        return callback(nil, err_stat or "stat failed")
      end
      uv.fs_read(fd, stat.size, 0, function(err_read, data)
        uv.fs_close(fd, function() end)
        if err_read then return callback(nil, err_read) end
        callback(data)
      end)
    end)
  end)
end

--- Async write entire file via uv
---@param path string
---@param data string
---@param callback fun(err: string|nil)
local function write_file_async(path, data, callback)
  uv.fs_open(path, "w", 420, function(err_open, fd)
    if err_open or not fd then return callback(err_open or "open failed") end
    uv.fs_write(fd, data, 0, function(err_write)
      uv.fs_close(fd, function() end)
      callback(err_write)
    end)
  end)
end

---Install the OpenCode JS plugin into .opencode/plugins/
---@param project_dir? string
---@param on_done? fun(ok: boolean)
function M.install_plugin(project_dir, on_done)
  project_dir = project_dir or vim.fn.getcwd()
  local util = require("fs-monitor.utils.util")
  on_done = on_done or function() end

  local server_addr = vim.v.servername
  if not server_addr or server_addr == "" then
    util.notify(
      "Neovim server address not available. Start Neovim with --listen or set NVIM_LISTEN_ADDRESS.",
      vim.log.levels.ERROR
    )
    return on_done(false)
  end

  local plugin_src = get_plugin_source_path()
  if not uv.fs_stat(plugin_src) then
    util.notify(fmt("Plugin source not found: %s", plugin_src), vim.log.levels.ERROR)
    return on_done(false)
  end

  -- Ensure directory exists (fast local op)
  local plugins_dir = vim.fs.joinpath(project_dir, ".opencode", "plugins")
  vim.fn.mkdir(plugins_dir, "p")

  local dest = vim.fs.joinpath(plugins_dir, "fs-monitor-plugin.js")

  read_file_async(plugin_src, function(data, err_read)
    if err_read or not data then
      vim.schedule(function()
        util.notify(fmt("Failed to read plugin source: %s", err_read), vim.log.levels.ERROR)
        on_done(false)
      end)
      return
    end

    -- Prepend the server address override
    local patched =
        fmt('process.env.NVIM_LISTEN_ADDRESS = process.env.NVIM_LISTEN_ADDRESS || "%s";\n%s', server_addr, data)

    write_file_async(dest, patched, function(err_write)
      vim.schedule(function()
        if err_write then
          util.notify(fmt("Failed to write plugin: %s", err_write), vim.log.levels.ERROR)
          on_done(false)
          return
        end

        debug_log(fmt("Installed plugin at %s with server_addr=%s", dest, server_addr))
        util.notify(fmt("OpenCode plugin installed: %s", dest))
        on_done(true)
      end)
    end)
  end)
end

---Remove the fs-monitor plugin from .opencode/plugins/
---@param project_dir? string
---@param on_done? fun()
function M.uninstall_plugin(project_dir, on_done)
  project_dir = project_dir or vim.fn.getcwd()
  local util = require("fs-monitor.utils.util")
  on_done = on_done or function() end

  local dest = vim.fs.joinpath(project_dir, ".opencode", "plugins", "fs-monitor-plugin.js")
  uv.fs_unlink(dest, function(err)
    vim.schedule(function()
      if not err then util.notify("OpenCode plugin removed") end
      on_done()
    end)
  end)
end

-- ============================================================================
-- RPC CALLBACKS (called by the JS plugin via nvim --remote-expr)
-- ============================================================================

---Called when OpenCode edits a file
---@param file_path string
---@return string Always returns "" (required by --remote-expr)
function M._on_file_changed(file_path)
  debug_log(fmt("_on_file_changed called: file=%s session=%s", file_path, M._session_id or "nil"))
  if not M._session_id then
    debug_log("SKIP: no active session")
    return ""
  end

  local fs_monitor = require("fs-monitor")
  local session = fs_monitor.get_session(M._session_id)
  if not session then
    debug_log(fmt("SKIP: session %s not found", M._session_id))
    return ""
  end

  local cwd = session.metadata.cwd or vim.fn.getcwd()
  local abs_path = vim.fs.normalize(file_path)
  if not vim.startswith(abs_path, "/") then abs_path = vim.fs.joinpath(cwd, abs_path) end
  debug_log(fmt("Resolved path: %s (cwd=%s)", abs_path, cwd))

  local watch_id = session.active_watcher_id
  debug_log(fmt("active_watcher_id: %s", watch_id or "nil"))

  if watch_id then
    debug_log("Using _process_file_change via watch_id")
    session.monitor:_process_file_change(watch_id, abs_path)
  else
    local relative = session.monitor:_get_relative_path(abs_path, cwd)
    debug_log(fmt("Manual read for relative path: %s", relative))
    session.monitor:_read_file_async(abs_path, function(content, err)
      vim.schedule(function()
        if err then
          debug_log(fmt("Read error: %s", err))
          if err:match("ENOENT") or err:match("no such file") then
            session.monitor:_register_change({
              path = relative,
              kind = "deleted",
              old_content = nil,
              new_content = nil,
              timestamp = uv.hrtime(),
              tool_name = "opencode",
              metadata = { source = "opencode_plugin" },
            })
            debug_log("Registered DELETED change")
          end
          return
        end

        debug_log(fmt("Read OK: %d bytes, registering change", content and #content or 0))
        session.monitor:_register_change({
          path = relative,
          kind = "modified",
          old_content = nil,
          new_content = content,
          timestamp = uv.hrtime(),
          tool_name = "opencode",
          metadata = { source = "opencode_plugin" },
        })
        debug_log(fmt("Registered MODIFIED change. Total changes: %d", #session.monitor.changes))
      end)
    end)
  end

  return ""
end

---Called when OpenCode session completes
---@return string Always returns ""
function M._on_session_complete()
  if not M._session_id then return "" end

  M._cycle = M._cycle + 1
  local session_id = M._session_id

  local fs_monitor = require("fs-monitor")
  local session = fs_monitor.get_session(session_id)
  if not session then return "" end

  local changes = fs_monitor.get_changes(session_id)
  if #changes > 0 then
    local label = fmt("Response #%d", M._cycle)
    fs_monitor.create_checkpoint(session_id, label)
    log:debug("OpenCode: checkpoint '%s' with %d changes", label, #changes)
  end

  return ""
end

-- ============================================================================
-- SSE EVENT HANDLING
-- ============================================================================

---Handle an SSE event from OpenCode server
---@param event table
local function handle_sse_event(event)
  if not M._session_id then return end

  local event_type = event.type

  if event_type == "file.edited" then
    local props = event.properties or {}
    local file_path = props.file or props.path
    if file_path then M._on_file_changed(file_path) end
  elseif event_type == "tool.execute.after" then
    local props = event.properties or {}
    local file_path = props.file_path or props.filePath or (props.args and props.args.file_path)
    if file_path then M._on_file_changed(file_path) end
  elseif event_type == "session.idle" then
    M._on_session_complete()
  end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

---Start an OpenCode monitoring session
---@param opts? { port?: number, mode?: "sse"|"plugin" }
---@return string|nil session_id
function M.start(opts)
  opts = opts or {}
  local util = require("fs-monitor.utils.util")
  local fs_monitor = require("fs-monitor")

  if M._session_id then
    local existing = fs_monitor.get_session(M._session_id)
    if existing then
      util.notify(fmt("OpenCode session already active: %s", M._session_id), vim.log.levels.WARN)
      return M._session_id
    end
    M._session_id = nil
  end

  local cwd = vim.fn.getcwd()

  ---Create session and start monitoring
  ---@param mode string "sse" or "plugin"
  ---@param port? number
  local function create_and_start(mode, port)
    local session = fs_monitor.create_session({
      id = "opencode_" .. os.time(),
      metadata = {
        source = "opencode",
        cwd = cwd,
        port = port,
        mode = mode,
        started_at = os.date("%Y-%m-%d %H:%M:%S"),
      },
    })

    M._session_id = session.id
    M._port = port
    M._mode = mode
    M._cycle = 0

    -- Prepopulate cache ONLY (no uv.fs_event watcher)
    -- File changes come exclusively from plugin events or SSE
    -- User edits in Neovim are NOT tracked
    fs_monitor.prepopulate(session.id, cwd, {
      recursive = true,
      on_ready = function(stats)
        vim.schedule(function()
          if mode == "sse" and port then
            M._sse_handle = start_sse_stream(port, handle_sse_event)
            if M._sse_handle then
              util.notify(fmt("OpenCode monitoring started (SSE, port %d, %d files cached)", port, stats.files_cached))
            else
              util.notify("Failed to start SSE stream, falling back to plugin", vim.log.levels.WARN)
              M._mode = "plugin"
              M.install_plugin(cwd)
            end
          else
            util.notify(fmt("OpenCode monitoring started (plugin, %d files cached)", stats.files_cached))
          end
        end)
      end,
    })
  end

  -- If user specified port, try SSE directly
  if opts.port then
    vim.system(
      { "curl", "-sf", "--max-time", "2", fmt("http://127.0.0.1:%d/global/health", opts.port) },
      { text = true },
      function(result)
        vim.schedule(function()
          if result.code == 0 then
            create_and_start("sse", opts.port)
          else
            util.notify(fmt("No OpenCode server on port %d, using plugin mode", opts.port), vim.log.levels.WARN)
            M.install_plugin(cwd)
            create_and_start("plugin")
          end
        end)
      end
    )
    return nil
  end

  if opts.mode == "plugin" then
    M.install_plugin(cwd)
    create_and_start("plugin")
    return nil
  end

  -- Auto-detect: try to find a running server, fall back to plugin
  discover_instances(function(instances)
    if #instances == 0 then
      M.install_plugin(cwd, function(ok)
        if ok then
          create_and_start("plugin")
        else
          util.notify("Failed to install OpenCode plugin", vim.log.levels.ERROR)
        end
      end)
      return
    end

    if #instances == 1 then
      create_and_start("sse", instances[1].port)
      return
    end

    local items = {}
    for _, inst in ipairs(instances) do
      table.insert(items, fmt("Port %d (v%s)", inst.port, inst.version or "?"))
    end

    vim.ui.select(items, {
      prompt = "Select OpenCode instance:",
    }, function(_, idx)
      if idx then create_and_start("sse", instances[idx].port) end
    end)
  end)

  return nil
end

---Stop the OpenCode monitoring session
---@param opts? { keep_plugin?: boolean }
function M.stop(opts)
  opts = opts or {}
  local util = require("fs-monitor.utils.util")

  if not M._session_id then
    util.notify("No active OpenCode session", vim.log.levels.WARN)
    return
  end

  local session_id = M._session_id

  -- Kill SSE stream if active
  if M._sse_handle then
    pcall(function()
      M._sse_handle:kill("SIGTERM")
    end)
    M._sse_handle = nil
  end

  -- Keep the plugin installed by default (it's harmless when no session is active)
  if not opts.keep_plugin and M._mode == "plugin" then M.uninstall_plugin() end

  require("fs-monitor").destroy(session_id, function()
    vim.schedule(function()
      util.notify(fmt("OpenCode session stopped: %s", session_id))
    end)
  end)

  M._session_id = nil
  M._port = nil
  M._cycle = 0
end

---Show diff for the active OpenCode session
function M.show()
  if not M._session_id then
    require("fs-monitor.utils.util").notify("No active OpenCode session", vim.log.levels.WARN)
    return
  end
  require("fs-monitor").show_diff(M._session_id)
end

---Check if an OpenCode session is active
---@return boolean
function M.is_active()
  return M._session_id ~= nil
end

---Get the active session ID
---@return string|nil
function M.get_session_id()
  return M._session_id
end

return M
