---@module "fs-monitor.types"
--- Claude Code adapter for fs-monitor.nvim
--- Tracks file changes made by Claude Code via hook scripts.
---
--- Strategy:
---  - PreToolUse:  activate the FS watcher to catch ALL disk changes
---  - PostToolUse: (Write|Edit) also register the specific file as backup
---  - Stop:        pause watcher → collect changes → checkpoint → re-prepopulate
---
--- This dual approach catches everything: Write, Edit, AND bash mv/cat/sed.

local uv = vim.uv
local log = require("fs-monitor.log")
local fmt = string.format
local fs = vim.fs

--- File-based debug log (always writes, regardless of log level)
---@param msg string
local function debug_log(msg)
  local ts = os.date("%H:%M:%S")
  local line = fmt("[%s][claude] %s\n", ts, msg)
  local fd = io.open("/tmp/fs-monitor-debug.log", "a")
  if fd then
    fd:write(line)
    fd:close()
  end
  log:debug(msg)
end

local M = {}

---@type string|nil Active session ID for claude adapter
M._session_id = nil

---@type number Response cycle counter for checkpoint labels
M._cycle = 0

---@type boolean Whether hooks have been installed for the current project
M._hooks_installed = false

---@type boolean Whether the FS watcher is currently active (tool in progress)
M._watcher_active = false

-- ============================================================================
-- HOOK INSTALLATION
-- ============================================================================

---Get the path to the hook script shipped with the plugin
---@return string
local function get_hook_script_path()
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = fs.normalize(fs.joinpath(fs.dirname(source), "..", "..", ".."))
  return fs.joinpath(plugin_root, "scripts", "fs-monitor-claude-hook.sh")
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
---@param mode? integer default 0o644
---@param callback fun(err: string|nil)
local function write_file_async(path, data, mode, callback)
  if type(mode) == "function" then
    callback = mode
    mode = 420 -- 0o644
  end
  uv.fs_open(path, "w", mode or 420, function(err_open, fd)
    if err_open or not fd then return callback(err_open or "open failed") end
    uv.fs_write(fd, data, 0, function(err_write)
      uv.fs_close(fd, function() end)
      callback(err_write)
    end)
  end)
end

--- Build the hooks settings table with our entries
---@param server_addr string
---@param existing_settings table|nil
---@return table settings
local function build_hook_settings(server_addr, existing_settings)
  local settings = existing_settings or {}
  local hook_cmd = fmt('NVIM_FSMONITOR_ADDR=%s "$CLAUDE_PROJECT_DIR"/.claude/hooks/fs-monitor-hook.sh', server_addr)

  settings.hooks = settings.hooks or {}

  -- Remove existing fs-monitor entries (prevents duplicates on re-install)
  for event_name, groups in pairs(settings.hooks) do
    if type(groups) == "table" then
      local filtered = {}
      for _, group in ipairs(groups) do
        local is_ours = false
        for _, h in ipairs(group.hooks or {}) do
          if h.command and h.command:find("fs-monitor") then
            is_ours = true
            break
          end
        end
        if not is_ours then table.insert(filtered, group) end
      end
      settings.hooks[event_name] = filtered
    end
  end

  -- PreToolUse: ANY tool — activates the FS watcher
  settings.hooks.PreToolUse = settings.hooks.PreToolUse or {}
  table.insert(settings.hooks.PreToolUse, {
    hooks = { { type = "command", command = hook_cmd } },
  })

  -- PostToolUse: Write|Edit|Bash — pauses watcher + registers file
  settings.hooks.PostToolUse = settings.hooks.PostToolUse or {}
  table.insert(settings.hooks.PostToolUse, {
    matcher = "Write|Edit|Bash",
    hooks = { { type = "command", command = hook_cmd } },
  })

  -- Stop
  settings.hooks.Stop = settings.hooks.Stop or {}
  table.insert(settings.hooks.Stop, {
    hooks = { { type = "command", command = hook_cmd } },
  })

  -- SessionStart
  settings.hooks.SessionStart = settings.hooks.SessionStart or {}
  table.insert(settings.hooks.SessionStart, {
    matcher = "startup",
    hooks = { { type = "command", command = hook_cmd } },
  })

  return settings
end

---Install Claude Code hooks into the project's .claude/settings.local.json (async)
---@param project_dir? string Project directory (default: cwd)
---@param on_done? fun(ok: boolean) Callback when installation completes
function M.install_hooks(project_dir, on_done)
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

  local hook_script = get_hook_script_path()
  if not uv.fs_stat(hook_script) then
    util.notify(fmt("Hook script not found: %s", hook_script), vim.log.levels.ERROR)
    return on_done(false)
  end

  local claude_dir = fs.joinpath(project_dir, ".claude")
  local hooks_dir = fs.joinpath(claude_dir, "hooks")
  vim.fn.mkdir(hooks_dir, "p")

  local dest_script = fs.joinpath(hooks_dir, "fs-monitor-hook.sh")
  local settings_path = fs.joinpath(claude_dir, "settings.local.json")

  read_file_async(hook_script, function(script_data, err_read)
    if err_read or not script_data then
      vim.schedule(function()
        util.notify(fmt("Failed to read hook script: %s", err_read), vim.log.levels.ERROR)
        on_done(false)
      end)
      return
    end

    write_file_async(dest_script, script_data, 493, function(err_write_script)
      if err_write_script then
        vim.schedule(function()
          util.notify(fmt("Failed to write hook script: %s", err_write_script), vim.log.levels.ERROR)
          on_done(false)
        end)
        return
      end

      read_file_async(settings_path, function(settings_data)
        local settings = {}
        if settings_data then
          local ok_decode, decoded = pcall(vim.json.decode, settings_data)
          if ok_decode and decoded then settings = decoded end
        end

        settings = build_hook_settings(server_addr, settings)
        local json = vim.json.encode(settings)

        write_file_async(settings_path, json, nil, function(err_write_settings)
          vim.schedule(function()
            if err_write_settings then
              util.notify(fmt("Failed to write settings: %s", err_write_settings), vim.log.levels.ERROR)
              on_done(false)
              return
            end

            M._hooks_installed = true
            debug_log(fmt("Hooks installed: %s (server=%s)", settings_path, server_addr))
            util.notify(fmt("Claude Code hooks installed in %s", settings_path))
            on_done(true)
          end)
        end)
      end)
    end)
  end)
end

---Remove fs-monitor hooks from .claude/settings.local.json
---@param project_dir? string
---@param on_done? fun()
function M.uninstall_hooks(project_dir, on_done)
  project_dir = project_dir or vim.fn.getcwd()
  local util = require("fs-monitor.utils.util")
  on_done = on_done or function() end
  local settings_path = fs.joinpath(project_dir, ".claude", "settings.local.json")

  read_file_async(settings_path, function(data)
    if not data then return on_done() end

    local ok_decode, settings = pcall(vim.json.decode, data)
    if not ok_decode or not settings or not settings.hooks then return on_done() end

    for event_name, groups in pairs(settings.hooks) do
      if type(groups) == "table" then
        local filtered = {}
        for _, group in ipairs(groups) do
          local is_ours = false
          for _, h in ipairs(group.hooks or {}) do
            if h.command and h.command:find("fs-monitor") then
              is_ours = true
              break
            end
          end
          if not is_ours then table.insert(filtered, group) end
        end
        settings.hooks[event_name] = #filtered > 0 and filtered or nil
      end
    end

    write_file_async(settings_path, vim.json.encode(settings), nil, function()
      local hook_script_path = fs.joinpath(project_dir, ".claude", "hooks", "fs-monitor-hook.sh")
      uv.fs_unlink(hook_script_path, function()
        vim.schedule(function()
          M._hooks_installed = false
          util.notify("Claude Code hooks removed")
          on_done()
        end)
      end)
    end)
  end)
end

-- ============================================================================
-- RPC CALLBACKS (called by the hook script via nvim --remote-expr)
-- ============================================================================

---Called on PreToolUse: activate the FS watcher to catch all disk changes
---@param tool_name string
---@return string
function M._on_pre_tool_use(tool_name)
  local session_id = M._session_id
  debug_log(
    fmt(
      "_on_pre_tool_use: tool=%s session=%s watcher_active=%s",
      tool_name or "?",
      session_id or "nil",
      tostring(M._watcher_active)
    )
  )
  if not session_id then return "" end
  if M._watcher_active then return "" end

  local fs_monitor = require("fs-monitor")
  local session = fs_monitor.get_session(session_id)
  if not session then return "" end

  if session.active_watcher_id then
    local ok = fs_monitor.activate_watcher(session_id)
    if ok then
      M._watcher_active = true
      debug_log(fmt("Watcher activated for tool: %s", tool_name))
    else
      debug_log("WARN: Failed to activate watcher")
    end
  else
    debug_log("WARN: No active_watcher_id, cannot activate watcher")
  end

  return ""
end

---Called on PostToolUse (Write|Edit|Bash): pause watcher + register specific file
---The watcher is paused so user edits between tool uses aren't tracked.
---Changes accumulate in the session; checkpoint is created on Stop.
---@param file_path string Absolute or relative file path (may be empty for Bash)
---@param tool_name string The Claude tool name (Write, Edit, Bash)
---@return string
function M._on_file_changed(file_path, tool_name)
  local session_id = M._session_id
  debug_log(
    fmt(
      "_on_file_changed (PostToolUse): file=%s tool=%s session=%s watcher=%s",
      file_path or "?",
      tool_name or "?",
      session_id or "nil",
      tostring(M._watcher_active)
    )
  )
  if not session_id then return "" end

  local fs_monitor = require("fs-monitor")
  local session = fs_monitor.get_session(session_id)
  if not session then return "" end

  if M._watcher_active then
    fs_monitor.pause(session_id, function(watcher_changes)
      vim.schedule(function()
        M._watcher_active = false
        debug_log(fmt("Watcher paused after %s: %d changes collected", tool_name, #watcher_changes))
      end)
    end)
  end

  if not file_path or file_path == "" then
    debug_log(fmt("No file_path for tool=%s, watcher handled it", tool_name))
    return ""
  end

  local cwd = session.metadata.cwd or vim.fn.getcwd()
  local abs_path = fs.normalize(file_path)
  if not vim.startswith(abs_path, "/") then abs_path = fs.joinpath(cwd, abs_path) end

  if session.active_watcher_id then
    debug_log(fmt("Processing file change: %s", abs_path))
    session.monitor:_process_file_change(session.active_watcher_id, abs_path)
  else
    local relative = session.monitor:_get_relative_path(abs_path, cwd)
    debug_log(fmt("Manual read for: %s", relative))
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
              tool_name = tool_name or "claude",
              metadata = { source = "claude_hook" },
            })
          end
          return
        end

        session.monitor:_register_change({
          path = relative,
          kind = "modified",
          old_content = nil,
          new_content = content,
          timestamp = uv.hrtime(),
          tool_name = tool_name or "claude",
          metadata = { source = "claude_hook" },
        })
        debug_log(fmt("Registered change. Total: %d", #session.monitor.changes))
      end)
    end)
  end

  return ""
end

---Called on Stop/SessionEnd: pause watcher, collect changes, checkpoint, re-prepopulate
---@return string
function M._on_session_end()
  local session_id = M._session_id
  debug_log(fmt("_on_session_end: session=%s watcher_active=%s", session_id or "nil", tostring(M._watcher_active)))
  if not session_id then return "" end

  M._cycle = M._cycle + 1
  local cycle = M._cycle

  local fs_monitor = require("fs-monitor")
  local session = fs_monitor.get_session(session_id)
  if not session then return "" end

  if M._watcher_active then
    fs_monitor.pause(session_id, function(watcher_changes)
      vim.schedule(function()
        M._watcher_active = false
        local total = fs_monitor.get_changes(session_id)
        debug_log(fmt("Watcher paused: %d new changes, %d total", #watcher_changes, #total))

        if #total > 0 then
          local label = fmt("Response #%d", cycle)
          fs_monitor.create_checkpoint(session_id, label)
          debug_log(fmt("Checkpoint '%s' with %d changes", label, #total))
        end

        local cwd = session.metadata.cwd or vim.fn.getcwd()
        fs_monitor.prepopulate(session_id, cwd, {
          recursive = true,
          on_ready = function(stats)
            debug_log(fmt("Re-prepopulated: %d files cached", stats.files_cached))
          end,
        })
      end)
    end)
  else
    -- No watcher was active — just checkpoint accumulated manual changes
    local changes = fs_monitor.get_changes(session_id)
    if #changes > 0 then
      local label = fmt("Response #%d", cycle)
      fs_monitor.create_checkpoint(session_id, label)
      debug_log(fmt("Checkpoint '%s' with %d changes (no watcher)", label, #changes))
    end
  end

  return ""
end

---Called on SessionStart
---@return string
function M._on_session_start()
  debug_log(
    fmt(
      "_on_session_start: session=%s auto=%s",
      M._session_id or "nil",
      tostring(vim.g.fs_monitor_claude_auto or false)
    )
  )

  -- Auto-start: if enabled and no session, start one automatically
  if not M._session_id and vim.g.fs_monitor_claude_auto then
    debug_log("Auto-starting Claude session")
    -- Hooks are already installed (the RPC reached us), skip re-install
    M.start({ install_hooks = false })
  end

  return ""
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

---Start a Claude Code monitoring session
---@param opts? { project_dir?: string, install_hooks?: boolean }
---@return string|nil session_id
function M.start(opts)
  opts = opts or {}
  local util = require("fs-monitor.utils.util")
  local fs_monitor = require("fs-monitor")

  if M._session_id then
    local existing = fs_monitor.get_session(M._session_id)
    if existing then
      util.notify(fmt("Claude session already active: %s", M._session_id), vim.log.levels.WARN)
      return M._session_id
    end
    M._session_id = nil
  end

  local cwd = opts.project_dir or vim.fn.getcwd()

  -- Create session first so we have an ID immediately
  local session = fs_monitor.create_session({
    id = "claude_" .. os.time(),
    metadata = {
      source = "claude",
      cwd = cwd,
      started_at = os.date("%Y-%m-%d %H:%M:%S"),
    },
  })

  M._session_id = session.id
  M._cycle = 0
  M._watcher_active = false

  debug_log(fmt("Starting session: %s cwd=%s", session.id, cwd))

  -- Prepopulate cache (watcher off — activated later via PreToolUse)
  fs_monitor.prepopulate(session.id, cwd, {
    recursive = true,
    on_ready = function(stats)
      vim.schedule(function()
        debug_log(fmt("Prepopulate done: %d files cached", stats.files_cached))
        util.notify(fmt("Claude monitoring started: %s (%d files cached)", session.id, stats.files_cached))
      end)
    end,
  })

  -- Install hooks async (fire-and-forget, runs in background)
  local install_hooks = opts.install_hooks ~= false
  if install_hooks then
    M._hooks_installed = false
    M.install_hooks(cwd, function(ok)
      if not ok then debug_log("WARN: Failed to install hooks") end
    end)
  end

  return session.id
end

---Stop the Claude Code monitoring session
---@param opts? { uninstall_hooks?: boolean }
function M.stop(opts)
  opts = opts or {}
  local util = require("fs-monitor.utils.util")

  local session_id = M._session_id
  if not session_id then
    util.notify("No active Claude session", vim.log.levels.WARN)
    return
  end

  M._session_id = nil
  M._cycle = 0
  M._watcher_active = false

  -- Uninstall hooks async (fire-and-forget)
  if opts.uninstall_hooks then M.uninstall_hooks() end

  require("fs-monitor").destroy(session_id, function()
    vim.schedule(function()
      util.notify(fmt("Claude session stopped: %s", session_id))
    end)
  end)
end

---Show diff for the active Claude session
function M.show()
  if not M._session_id then
    require("fs-monitor.utils.util").notify("No active Claude session", vim.log.levels.WARN)
    return
  end
  require("fs-monitor").show_diff(M._session_id)
end

---Check if a Claude session is active
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
