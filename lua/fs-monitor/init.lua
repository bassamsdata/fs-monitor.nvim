---@module "fs-monitor.types"

local M = {}

---Fire a User autocmd event
---@param pattern string Event pattern name
---@param data table Event data
local function fire_event(pattern, data)
  vim.api.nvim_exec_autocmds("User", {
    pattern = pattern,
    data = data,
  })
end

---@type table<string, FSMonitor.Session>
M._sessions = {}

---@type number
M._session_counter = 0

---Setup the plugin with user configuration
---@param opts? { monitor?: FSMonitor.Config, diff?: FSMonitor.DiffConfig }
function M.setup(opts)
  local config = require("fs-monitor.config")
  config.setup(opts)
end

---Create a new monitoring session
---@param opts? { id?: string, metadata?: table }
---@return FSMonitor.Session
function M.create_session(opts)
  opts = opts or {}
  local cfg = require("fs-monitor.config").options

  M._session_counter = M._session_counter + 1
  local session_id = opts.id or string.format("session_%d_%d", M._session_counter, vim.uv.hrtime())

  local Monitor = require("fs-monitor.monitor")
  local monitor = Monitor.new({
    debounce_ms = cfg.debounce_ms,
    max_file_size = cfg.max_file_size,
    max_prepopulate_files = cfg.max_prepopulate_files,
    max_depth = cfg.max_depth,
    max_cache_bytes = cfg.max_cache_bytes,
    ignore_patterns = cfg.ignore_patterns,
    respect_gitignore = cfg.respect_gitignore,
    never_ignore = cfg.never_ignore,
    session_id = session_id,
  })

  ---@type FSMonitor.Session
  local session = {
    id = session_id,
    monitor = monitor,
    changes = {},
    checkpoints = {},
    watch_id = nil,
    started_at = vim.uv.hrtime(),
    metadata = opts.metadata or {},
  }

  M._sessions[session_id] = session

  return session
end

---Get an existing session by ID
---@param session_id string
---@return FSMonitor.Session|nil
function M.get_session(session_id)
  return M._sessions[session_id]
end

---Get all active sessions
---@return table<string, FSMonitor.Session>
function M.get_all_sessions()
  return M._sessions
end

---Start monitoring for a session (first time or resume)
---@param session_id string
---@param target_path? string Path to monitor (default: cwd)
---@param opts? { prepopulate?: boolean, recursive?: boolean, on_ready?: fun(stats: FSMonitor.PrepopulateStats) }
---@return string|nil watch_id
function M.start(session_id, target_path, opts)
  local session = M._sessions[session_id]
  if not session then
    require("fs-monitor.utils.util").notify(string.format("Session not found: %s", session_id), vim.log.levels.ERROR)
    return nil
  end

  target_path = target_path or vim.fn.getcwd()
  opts = opts or {}

  if opts.prepopulate == nil then opts.prepopulate = true end
  if opts.recursive == nil then opts.recursive = true end

  local watch_id = session.monitor:start_monitoring("workspace", target_path, {
    prepopulate = opts.prepopulate,
    recursive = opts.recursive,
    on_ready = opts.on_ready,
  })

  if watch_id and watch_id ~= "" then
    session.watch_id = watch_id

    fire_event("FSMonitorStarted", {
      session_id = session_id,
      target_path = target_path,
      watch_id = watch_id,
      prepopulate = opts.prepopulate,
      recursive = opts.recursive,
    })

    return watch_id
  end

  return nil
end

---Pause monitoring for a session
---@param session_id string
---@param callback? fun(changes: FSMonitor.Change[])
function M.pause(session_id, callback)
  local session = M._sessions[session_id]
  if not session then
    if callback then callback({}) end
    return
  end

  if not session.watch_id then
    if callback then callback({}) end
    return
  end

  local watch_id = session.watch_id

  session.monitor:stop_monitoring_async(watch_id, function(new_changes)
    vim.list_extend(session.changes, new_changes)
    session.watch_id = nil

    fire_event("FSMonitorStopped", {
      session_id = session_id,
      watch_id = watch_id,
      change_count = #new_changes,
      total_changes = #session.changes,
    })

    if callback then callback(new_changes) end
  end)
end

---Resume monitoring for an existing session
---@param session_id string
---@param target_path? string Path to monitor (default: cwd)
---@param opts? { prepopulate?: boolean, recursive?: boolean, on_ready?: fun(stats: FSMonitor.PrepopulateStats) }
---@return string|nil watch_id
function M.resume(session_id, target_path, opts)
  local session = M._sessions[session_id]
  if not session then
    require("fs-monitor.utils.util").notify(
      string.format("Cannot resume: session not found: %s", session_id),
      vim.log.levels.ERROR
    )
    return nil
  end

  if session.watch_id then
    require("fs-monitor.utils.util").notify(
      string.format("Session already monitoring: %s", session_id),
      vim.log.levels.WARN
    )
    return session.watch_id
  end

  return M.start(session_id, target_path, opts)
end

---Stop and finalize session (prompts for confirmation if changes exist)
---@param session_id string
---@param opts? { force?: boolean, callback?: fun() }
function M.stop(session_id, opts)
  opts = opts or {}
  local session = M._sessions[session_id]
  if not session then
    if opts.callback then opts.callback() end
    return
  end

  local changes = session.monitor:get_all_changes()
  local has_changes = #changes > 0

  local function do_destroy()
    M.destroy(session_id, opts.callback)
  end

  if opts.force or not has_changes then
    do_destroy()
    return
  end

  vim.ui.select({ "Yes", "No" }, {
    prompt = string.format("Stop session '%s' and destroy %d change(s)?", session_id, #changes),
  }, function(choice)
    if choice == "Yes" then
      do_destroy()
    elseif opts.callback then
      opts.callback()
    end
  end)
end

---Create a checkpoint for a session
---@param session_id string
---@param label? string Optional label for the checkpoint
---@return FSMonitor.Checkpoint|nil
function M.create_checkpoint(session_id, label)
  local session = M._sessions[session_id]
  if not session then return nil end

  local checkpoint = session.monitor:create_checkpoint()
  checkpoint.label = label
  table.insert(session.checkpoints, checkpoint)

  fire_event("FSMonitorCheckpoint", {
    session_id = session_id,
    checkpoint_index = #session.checkpoints,
    label = label,
    change_count = checkpoint.change_count,
    timestamp = checkpoint.timestamp,
  })

  return checkpoint
end

---Get all changes for a session
---@param session_id string
---@return FSMonitor.Change[]
function M.get_changes(session_id)
  local session = M._sessions[session_id]
  if not session then return {} end

  return session.monitor:get_all_changes()
end

---Get checkpoints for a session
---@param session_id string
---@return FSMonitor.Checkpoint[]
function M.get_checkpoints(session_id)
  local session = M._sessions[session_id]
  if not session then return {} end

  return session.checkpoints
end

---Show the diff viewer for a session
---@param session_id string
---@param opts? { on_revert?: fun(changes: FSMonitor.Change[], checkpoints: FSMonitor.Checkpoint[]) }
function M.show_diff(session_id, opts)
  opts = opts or {}
  local util = require("fs-monitor.utils.util")
  local session = M._sessions[session_id]
  if not session then
    util.notify(string.format("Session not found: %s", session_id), vim.log.levels.ERROR)
    return
  end

  session.monitor:flush_pending_and_get_changes(function(changes)
    if not changes or #changes == 0 then
      util.notify("No file changes tracked yet")
      return
    end

    local diff = require("fs-monitor.diff")
    diff.show(changes, session.checkpoints, {
      fs_monitor = session.monitor,
      on_revert = function(new_changes, new_checkpoints)
        session.changes = new_changes
        session.checkpoints = new_checkpoints

        if opts.on_revert then opts.on_revert(new_changes, new_checkpoints) end
      end,
    })
  end)
end

---Revert to a checkpoint
---@param session_id string
---@param checkpoint_idx number
---@return table|nil result
function M.revert_to_checkpoint(session_id, checkpoint_idx)
  local session = M._sessions[session_id]
  if not session then return nil end

  local result = session.monitor:revert_to_checkpoint(checkpoint_idx, session.checkpoints)
  if result then
    session.changes = result.new_changes
    session.checkpoints = result.new_checkpoints
  end

  return result
end

---Tag changes in a time range with tool information
---@param session_id string
---@param start_time number
---@param end_time number
---@param tool_name string
---@param tool_args? table
function M.tag_changes(session_id, start_time, end_time, tool_name, tool_args)
  local session = M._sessions[session_id]
  if not session then return end

  session.monitor:tag_changes_in_range(start_time, end_time, tool_name, tool_args)
end

---Destroy a session and clean up resources
---@param session_id string
---@param callback? fun()
function M.destroy(session_id, callback)
  local session = M._sessions[session_id]
  if not session then
    if callback then callback() end
    return
  end

  session.monitor:stop_all_async(function()
    M._sessions[session_id] = nil
    if callback then callback() end
  end)
end

---Clear all sessions
---@param callback? fun()
function M.clear_all(callback)
  local session_ids = vim.tbl_keys(M._sessions)
  local remaining = #session_ids

  if remaining == 0 then
    if callback then callback() end
    return
  end

  for _, session_id in ipairs(session_ids) do
    M.destroy(session_id, function()
      remaining = remaining - 1
      if remaining == 0 and callback then callback() end
    end)
  end
end

---Get statistics for a session
---@param session_id string
---@return table|nil stats
function M.get_stats(session_id)
  local session = M._sessions[session_id]
  if not session then return nil end

  return session.monitor:get_stats()
end

-- Expose sub-modules for direct access (lazy loaded)
---@type FSMonitor.Monitor
M.Monitor = nil

---@type FSMonitor.Diff
M.Diff = nil

setmetatable(M, {
  __index = function(t, k)
    if k == "Monitor" then
      t.Monitor = require("fs-monitor.monitor")
      return t.Monitor
    elseif k == "Diff" then
      t.Diff = require("fs-monitor.diff")
      return t.Diff
    end
  end,
})

return M
