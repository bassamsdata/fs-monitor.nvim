-- fs-monitor.nvim plugin entry point
-- File system monitoring for AI/LLM tool execution tracking

if vim.g.loaded_fs_monitor then return end
vim.g.loaded_fs_monitor = true

-- Single unified command with subcommands
vim.api.nvim_create_user_command("FSMonitor", function(opts)
  local args = vim.split(opts.args, "%s+", { trimempty = true })
  local subcmd = args[1] or "help"
  local fs_monitor = require("fs-monitor")
  local util = require("fs-monitor.utils.util")

  if subcmd == "start" then
    local session_id = args[2]
    local session = fs_monitor.create_session({ id = session_id })
    fs_monitor.start(session.id, vim.fn.getcwd(), {
      on_ready = function(stats)
        vim.schedule(function()
          util.notify(string.format("Session started: %s (%d files cached)", session.id, stats.files_cached))
        end)
      end,
    })
  elseif subcmd == "pause" then
    local session_id = args[2]
    if not session_id or session_id == "" then
      util.notify("Session ID required for pause", vim.log.levels.WARN)
    else
      fs_monitor.pause(session_id, function(changes)
        vim.schedule(function()
          util.notify(string.format("Session paused: %s (%d changes)", session_id, #changes))
        end)
      end)
    end
  elseif subcmd == "resume" then
    local session_id = args[2]
    if not session_id or session_id == "" then
      util.notify("Session ID required for resume", vim.log.levels.WARN)
    else
      local watch_id = fs_monitor.resume(session_id, vim.fn.getcwd(), {
        on_ready = function(stats)
          vim.schedule(function()
            util.notify(string.format("Session resumed: %s (%d files cached)", session_id, stats.files_cached))
          end)
        end,
      })
      if not watch_id then
        vim.schedule(function()
          util.notify(string.format("Failed to resume session: %s", session_id), vim.log.levels.ERROR)
        end)
      end
    end
  elseif subcmd == "stop" then
    local session_id = args[2]
    if not session_id or session_id == "" then
      util.notify("Session ID required for stop", vim.log.levels.WARN)
    else
      fs_monitor.stop(session_id, {
        callback = function()
          vim.schedule(function()
            util.notify(string.format("Session stopped and destroyed: %s", session_id))
          end)
        end,
      })
    end
  elseif subcmd == "destroy" then
    local session_id = args[2]
    if not session_id or session_id == "" then
      fs_monitor.clear_all(function()
        vim.schedule(function()
          util.notify("All sessions destroyed")
        end)
      end)
    else
      fs_monitor.destroy(session_id, function()
        vim.schedule(function()
          util.notify(string.format("Session destroyed: %s", session_id))
        end)
      end)
    end
  elseif subcmd == "diff" or subcmd == "show" then
    local session_id = args[2]
    if not session_id or session_id == "" then
      local sessions = fs_monitor.get_all_sessions()
      local session_ids = vim.tbl_keys(sessions)

      if #session_ids == 0 then
        util.notify("No active sessions")
        return
      end

      if #session_ids == 1 then
        fs_monitor.show_diff(session_ids[1])
        return
      end

      vim.ui.select(session_ids, {
        prompt = "Select session to view:",
      }, function(selected)
        if selected then fs_monitor.show_diff(selected) end
      end)
    else
      fs_monitor.show_diff(session_id)
    end
  elseif subcmd == "stats" then
    local session_id = args[2]
    if not session_id or session_id == "" then
      local sessions = fs_monitor.get_all_sessions()
      local lines = { "fs-monitor Sessions:" }

      for id, _ in pairs(sessions) do
        local stats = fs_monitor.get_stats(id)
        if stats then
          table.insert(
            lines,
            string.format(
              "  %s: %d changes (%d created, %d modified, %d deleted)",
              id,
              stats.total_changes,
              stats.created,
              stats.modified,
              stats.deleted
            )
          )
        end
      end

      if #lines == 1 then table.insert(lines, "  (no active sessions)") end

      util.notify(table.concat(lines, "\n"))
    else
      local stats = fs_monitor.get_stats(session_id)
      if stats then
        util.notify(
          string.format(
            "%s: %d changes (%d created, %d modified, %d deleted)",
            session_id,
            stats.total_changes,
            stats.created,
            stats.modified,
            stats.deleted
          )
        )
      else
        util.notify(string.format("Session not found: %s", session_id), vim.log.levels.WARN)
      end
    end
  elseif subcmd == "help" then
    local help = {
      "FSMonitor - File System Monitor Commands",
      "",
      "Usage: :FSMonitor <subcommand> [args]",
      "",
      "Subcommands:",
      "  start [session_id]   - Start a new monitoring session",
      "  pause <session_id>   - Pause monitoring (keeps session alive)",
      "  resume <session_id>  - Resume monitoring existing session",
      "  stop <session_id>    - Stop and destroy session (with confirmation)",
      "  destroy [session_id] - Destroy session (or all if no ID, no confirmation)",
      "  diff [session_id]    - Show diff viewer for a session",
      "  show [session_id]    - Alias for 'diff'",
      "  stats [session_id]   - Show session statistics",
      "  help                 - Show this help message",
    }
    util.notify(table.concat(help, "\n"))
  else
    util.notify(string.format("Unknown subcommand: %s (use 'help' for usage)", subcmd), vim.log.levels.WARN)
  end
end, {
  nargs = "*",
  desc = "File System Monitor commands",
  complete = function(arg_lead, cmd_line, _)
    local args = vim.split(cmd_line, "%s+", { trimempty = true })
    local num_args = #args

    -- Complete subcommands
    if num_args == 1 or (num_args == 2 and not cmd_line:match("%s$")) then
      local subcommands = { "start", "pause", "resume", "stop", "destroy", "diff", "show", "stats", "help" }
      return vim.tbl_filter(function(s)
        return s:find(arg_lead, 1, true) == 1
      end, subcommands)
    end

    -- Complete session IDs for commands that need them
    if num_args >= 2 then
      local subcmd = args[2]
      if
        subcmd == "pause"
        or subcmd == "resume"
        or subcmd == "stop"
        or subcmd == "destroy"
        or subcmd == "diff"
        or subcmd == "show"
        or subcmd == "stats"
      then
        local ok, fs_monitor = pcall(require, "fs-monitor")
        if ok then
          local sessions = fs_monitor.get_all_sessions()
          local session_ids = vim.tbl_keys(sessions)
          return vim.tbl_filter(function(s)
            return s:find(arg_lead, 1, true) == 1
          end, session_ids)
        end
      end
    end

    return {}
  end,
})
