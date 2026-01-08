---@class CodeCompanion.Extensions.FSMonitor
-- CodeCompanion extension for fs-monitor.nvim
-- Provides automatic file system monitoring and diff viewing for LLM tool executions

local log = require("fs-monitor.log")
local fmt = string.format

local M = {}

---@type table<number, string> Maps chat IDs to session IDs
M._chat_sessions = {}

---@type table<number, number> Maps buffer numbers to chat IDs
M._bufnr_to_chat = {}

---@type number|nil
M._augroup = nil

---@type boolean
M._initialized = false

---@type table
M._opts = {}

---@type table Default options
local default_opts = {
  keymap = "gF",
  keymap_description = "Show file system diff (fs-monitor)",
  auto_start = true,
  auto_checkpoint = true,
  monitor = {
    debounce_ms = 300,
    max_file_size = 1024 * 1024 * 2,
    max_prepopulate_files = 2000,
    max_depth = 6,
    max_cache_bytes = 1024 * 1024 * 50,
    respect_gitignore = true,
    debug = false,
  },
}

---Get chat instance from buffer number
---@param bufnr number
---@return table|nil chat
---TODO: use this for goto file funtion so files doesn't open in chat window.
local function _get_chat_from_bufnr(bufnr)
  local ok, chat_module = pcall(require, "codecompanion.interactions.chat")
  if not ok then
    ok, chat_module = pcall(require, "codecompanion.strategies.chat")
  end
  if ok and chat_module and chat_module.buf_get_chat then return chat_module.buf_get_chat(bufnr) end
  return nil
end

---Show diff for a chat
---@param chat table The chat instance
local function show_diff(chat)
  local util = require("fs-monitor.utils.util")

  if not chat then
    util.notify("No chat provided", vim.log.levels.WARN)
    return
  end

  local session_id = M._chat_sessions[chat.id]
  if not session_id then
    util.notify("No monitoring session found for this chat", vim.log.levels.WARN)
    return
  end

  local fs_monitor = require("fs-monitor")
  fs_monitor.show_diff(session_id, {
    on_revert = function(new_changes, new_checkpoints)
      local session = fs_monitor.get_session(session_id)
      if session then
        session.changes = new_changes
        session.checkpoints = new_checkpoints
      end
    end,
  })
end

---Setup autocommands for automatic monitoring
local function setup_autocommands()
  M._augroup = vim.api.nvim_create_augroup("CodeCompanionFSMonitor", { clear = true })

  if M._opts.auto_start then
    vim.api.nvim_create_autocmd("User", {
      group = M._augroup,
      pattern = "CodeCompanionChatSubmitted",
      callback = function(event)
        local data = event.data or {}
        local chat_id = data.id
        local bufnr = data.bufnr

        if not chat_id then return end

        local fs_monitor = require("fs-monitor")
        local session_id = M._chat_sessions[chat_id]

        if not session_id then
          local session = fs_monitor.create_session({
            id = fmt("codecompanion_chat_%d", chat_id),
            metadata = { chat_id = chat_id, bufnr = bufnr, source = "codecompanion" },
          })

          session_id = session.id
          M._chat_sessions[chat_id] = session_id
          if bufnr then M._bufnr_to_chat[bufnr] = chat_id end

          log:debug("Created session %s for chat %d", session_id, chat_id)

          fs_monitor.start(session_id, vim.fn.getcwd(), {
            prepopulate = true,
            recursive = true,
            on_ready = function(stats)
              log:debug("Monitoring ready: %d files cached", stats.files_cached)
            end,
          })
        else
          local session = fs_monitor.get_session(session_id)
          if session and not session.watch_id then
            fs_monitor.start(session_id, vim.fn.getcwd(), {
              prepopulate = true,
              recursive = true,
            })
          end
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("User", {
    group = M._augroup,
    pattern = "CodeCompanionChatDone",
    callback = function(event)
      local data = event.data or {}
      local chat_id = data.id

      if not chat_id then return end

      local session_id = M._chat_sessions[chat_id]
      if not session_id then return end

      local fs_monitor = require("fs-monitor")
      local session = fs_monitor.get_session(session_id)
      if not session then return end

      fs_monitor.stop(session_id, function(changes)
        vim.schedule(function()
          if M._opts.auto_checkpoint and changes and #changes > 0 then
            local current_session = fs_monitor.get_session(session_id)
            local cycle = #(current_session and current_session.checkpoints or {}) + 1

            local checkpoint = fs_monitor.create_checkpoint(session_id, fmt("Response #%d", cycle))
            if checkpoint then
              checkpoint.cycle = cycle
              log:debug("Created checkpoint #%d with %d changes", cycle, #changes)
            end
          end
        end)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = M._augroup,
    pattern = "CodeCompanionToolStarted",
    callback = function(event)
      local data = event.data or {}
      local bufnr = data.bufnr
      local chat_id = data.id or (bufnr and M._bufnr_to_chat[bufnr])

      if not chat_id then return end

      local session_id = M._chat_sessions[chat_id]
      if not session_id then return end

      local session = require("fs-monitor").get_session(session_id)
      if session then
        session.metadata._tool_timings = session.metadata._tool_timings or {}
        local tool_key = data.id or data.tool or "unknown"
        session.metadata._tool_timings[tool_key] = {
          start_time = vim.uv.hrtime(),
          tool_name = data.tool or "unknown",
        }
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = M._augroup,
    pattern = "CodeCompanionToolFinished",
    callback = function(event)
      local data = event.data or {}
      local bufnr = data.bufnr
      local chat_id = data.id or (bufnr and M._bufnr_to_chat[bufnr])

      if not chat_id then return end

      local session_id = M._chat_sessions[chat_id]
      if not session_id then return end

      local fs_monitor = require("fs-monitor")
      local session = fs_monitor.get_session(session_id)

      if session and session.metadata._tool_timings then
        local tool_key = data.id or data.name or "unknown"
        local timing = session.metadata._tool_timings[tool_key]

        if timing then
          fs_monitor.tag_changes(session_id, timing.start_time, vim.uv.hrtime(), timing.tool_name, {})
          session.metadata._tool_timings[tool_key] = nil
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = M._augroup,
    pattern = "CodeCompanionChatClosed",
    callback = function(event)
      local data = event.data or {}
      local chat_id = data.id
      local bufnr = data.bufnr

      if not chat_id then return end

      local session_id = M._chat_sessions[chat_id]
      if session_id then
        log:debug("Destroying session %s for closed chat %d", session_id, chat_id)
        require("fs-monitor").destroy_session(session_id)
        M._chat_sessions[chat_id] = nil
      end

      if bufnr then M._bufnr_to_chat[bufnr] = nil end
    end,
  })
end

---Setup keymaps for chat buffers
local function setup_keymaps()
  local function form_modes(v)
    if type(v) == "string" then return { n = v } end
    return v
  end

  local keymaps = {
    fs_diff = {
      modes = form_modes(M._opts.keymap),
      index = 19,
      description = M._opts.keymap_description,
      callback = function(chat)
        show_diff(chat)
      end,
    },
  }

  local ok, cc_config = pcall(require, "codecompanion.config")
  if ok and cc_config then
    local chat_keymaps = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.keymaps
    if not chat_keymaps then
      chat_keymaps = cc_config.strategies and cc_config.strategies.chat and cc_config.strategies.chat.keymaps
    end

    if chat_keymaps then
      for name, keymap in pairs(keymaps) do
        chat_keymaps[name] = keymap
      end
    end
  end
end

---@type CodeCompanion.Extension
return {
  ---Setup the extension
  ---@param opts table
  setup = function(opts)
    if M._initialized then return end

    M._opts = vim.tbl_deep_extend("force", default_opts, opts or {})
    require("fs-monitor").setup(M._opts.monitor)

    setup_autocommands()
    setup_keymaps()

    M._initialized = true
    log:debug("CodeCompanion fs-monitor extension initialized")
  end,

  exports = {
    ---Show diff for a chat by ID
    ---@param chat_id number
    show_diff = function(chat_id)
      local session_id = M._chat_sessions[chat_id]
      if session_id then
        require("fs-monitor").show_diff(session_id)
      else
        require("fs-monitor.utils.util").notify("No session found for chat " .. tostring(chat_id), vim.log.levels.WARN)
      end
    end,

    ---Get changes for a chat
    ---@param chat_id number
    ---@return table changes
    get_changes = function(chat_id)
      local session_id = M._chat_sessions[chat_id]
      if session_id then return require("fs-monitor").get_changes(session_id) end
      return {}
    end,

    ---Get checkpoints for a chat
    ---@param chat_id number
    ---@return table checkpoints
    get_checkpoints = function(chat_id)
      local session_id = M._chat_sessions[chat_id]
      if session_id then return require("fs-monitor").get_checkpoints(session_id) end
      return {}
    end,

    ---Get stats for a chat
    ---@param chat_id number
    ---@return table|nil stats
    get_stats = function(chat_id)
      local session_id = M._chat_sessions[chat_id]
      if session_id then return require("fs-monitor").get_stats(session_id) end
      return nil
    end,

    ---Manually start monitoring for a chat
    ---@param chat_id number
    ---@param bufnr? number
    ---@return string|nil session_id
    start_monitoring = function(chat_id, bufnr)
      if M._chat_sessions[chat_id] then return M._chat_sessions[chat_id] end

      local fs_monitor = require("fs-monitor")
      local session = fs_monitor.create_session({
        id = fmt("codecompanion_chat_%d", chat_id),
        metadata = { chat_id = chat_id, bufnr = bufnr, source = "codecompanion" },
      })

      M._chat_sessions[chat_id] = session.id
      if bufnr then M._bufnr_to_chat[bufnr] = chat_id end

      fs_monitor.start(session.id)
      return session.id
    end,

    ---Manually stop monitoring for a chat
    ---@param chat_id number
    ---@param callback? fun(changes: table)
    stop_monitoring = function(chat_id, callback)
      local session_id = M._chat_sessions[chat_id]
      if session_id then
        require("fs-monitor").stop(session_id, callback or function() end)
      elseif callback then
        callback({})
      end
    end,

    ---Check if a chat has an active session
    ---@param chat_id number
    ---@return boolean
    has_session = function(chat_id)
      return M._chat_sessions[chat_id] ~= nil
    end,
  },
}
