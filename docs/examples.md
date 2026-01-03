# Integration Examples

This document provides examples for integrating fs-monitor.nvim with various AI/LLM tools and workflows.

## Basic Integration Pattern

The core pattern for integrating fs-monitor with any AI tool:

```lua
local fs_monitor = require("fs-monitor")

-- 1. Create a session when starting an AI interaction
local session = fs_monitor.create_session({
  id = "my-tool-" .. os.time(),
  metadata = { tool = "my-ai-tool" },
})

-- 2. Start monitoring before the AI makes changes
fs_monitor.start(session.id, vim.fn.getcwd(), {
  prepopulate = true,
  recursive = true,
  on_ready = function(stats)
    -- Monitoring is ready, safe to let AI proceed
  end,
})

-- 3. After AI response, stop monitoring and create checkpoint
fs_monitor.stop(session.id, function(changes)
  if #changes > 0 then
    fs_monitor.create_checkpoint(session.id, "Response 1")
  end
end)

-- 4. Show diff viewer when user requests
fs_monitor.show_diff(session.id)

-- 5. Clean up when done
fs_monitor.destroy_session(session.id)
```

## Claude Code / Agentic Tool Integration

For tools like Claude Code that make multiple file changes in a single session:

```lua
local fs_monitor = require("fs-monitor")

local ClaudeMonitor = {}
ClaudeMonitor.sessions = {}

function ClaudeMonitor.start_session(conversation_id)
  local session = fs_monitor.create_session({
    id = "claude-" .. conversation_id,
    metadata = {
      tool = "claude-code",
      conversation_id = conversation_id,
      started_at = os.date("%Y-%m-%d %H:%M:%S"),
    },
  })

  ClaudeMonitor.sessions[conversation_id] = {
    session_id = session.id,
    turn_count = 0,
  }

  fs_monitor.start(session.id, vim.fn.getcwd(), {
    prepopulate = true,
    on_ready = function(stats)
      vim.notify(
        string.format("[Claude] Monitoring ready (%d files cached)", stats.files_cached),
        vim.log.levels.INFO
      )
    end,
  })

  return session.id
end

function ClaudeMonitor.on_response_complete(conversation_id)
  local ctx = ClaudeMonitor.sessions[conversation_id]
  if not ctx then return end

  ctx.turn_count = ctx.turn_count + 1

  fs_monitor.stop(ctx.session_id, function(changes)
    if #changes > 0 then
      local label = string.format("Turn %d - %d changes", ctx.turn_count, #changes)
      fs_monitor.create_checkpoint(ctx.session_id, label)

      -- Restart monitoring for next turn
      fs_monitor.start(ctx.session_id)
    end
  end)
end

function ClaudeMonitor.show_changes(conversation_id)
  local ctx = ClaudeMonitor.sessions[conversation_id]
  if not ctx then return end

  fs_monitor.show_diff(ctx.session_id, {
    on_revert = function(changes, checkpoints)
      vim.notify(
        string.format("[Claude] Reverted. %d changes remaining.", #changes),
        vim.log.levels.INFO
      )
    end,
  })
end

function ClaudeMonitor.end_session(conversation_id)
  local ctx = ClaudeMonitor.sessions[conversation_id]
  if not ctx then return end

  fs_monitor.destroy_session(ctx.session_id, function()
    ClaudeMonitor.sessions[conversation_id] = nil
  end)
end

return ClaudeMonitor
```

## Multi-Tool Tracking

Track changes from multiple AI tools in the same session:

```lua
local fs_monitor = require("fs-monitor")

local MultiToolMonitor = {}
MultiToolMonitor.session_id = nil

function MultiToolMonitor.init()
  local session = fs_monitor.create_session({ id = "multi-tool-session" })
  MultiToolMonitor.session_id = session.id
  fs_monitor.start(session.id)
end

-- Call this before any tool executes
function MultiToolMonitor.before_tool(tool_name)
  MultiToolMonitor.current_tool = tool_name
  MultiToolMonitor.tool_start_time = vim.uv.hrtime()
end

-- Call this after any tool completes
function MultiToolMonitor.after_tool(tool_name, tool_args)
  if not MultiToolMonitor.session_id then return end

  local end_time = vim.uv.hrtime()

  -- Tag the changes made during this tool execution
  fs_monitor.tag_changes(
    MultiToolMonitor.session_id,
    MultiToolMonitor.tool_start_time,
    end_time,
    tool_name,
    tool_args
  )
end

-- Create checkpoint after a complete response
function MultiToolMonitor.checkpoint(label)
  if not MultiToolMonitor.session_id then return end
  fs_monitor.create_checkpoint(MultiToolMonitor.session_id, label)
end

function MultiToolMonitor.show()
  if not MultiToolMonitor.session_id then return end
  fs_monitor.show_diff(MultiToolMonitor.session_id)
end

return MultiToolMonitor
```

## Event-Based Integration

fs-monitor fires several User autocmd events you can hook into:

| Event | Data |
|-------|------|
| `FSMonitorStarted` | `{ session_id, target_path, watch_id, prepopulate, recursive }` |
| `FSMonitorStopped` | `{ session_id, watch_id, change_count, total_changes }` |
| `FSMonitorCheckpoint` | `{ session_id, checkpoint_index, label, change_count, timestamp }` |
| `FSMonitorFileChanged` | `{ session_id, path, kind, tool_name, timestamp, old_path? }` |

```lua
-- Track when monitoring starts
vim.api.nvim_create_autocmd("User", {
  pattern = "FSMonitorStarted",
  callback = function(event)
    local data = event.data
    vim.notify(
      string.format("[fs-monitor] Started monitoring: %s", data.target_path),
      vim.log.levels.INFO
    )
  end,
})

-- Track when monitoring stops
vim.api.nvim_create_autocmd("User", {
  pattern = "FSMonitorStopped",
  callback = function(event)
    local data = event.data
    if data.change_count > 0 then
      vim.notify(
        string.format("[fs-monitor] Stopped. %d new changes detected.", data.change_count),
        vim.log.levels.INFO
      )
    end
  end,
})

-- Track checkpoint creation
vim.api.nvim_create_autocmd("User", {
  pattern = "FSMonitorCheckpoint",
  callback = function(event)
    local data = event.data
    vim.notify(
      string.format(
        "[fs-monitor] Checkpoint '%s' created with %d changes",
        data.label or data.checkpoint_index,
        data.change_count
      ),
      vim.log.levels.INFO
    )
  end,
})

-- Listen for file changes in real-time
vim.api.nvim_create_autocmd("User", {
  pattern = "FSMonitorFileChanged",
  callback = function(event)
    local data = event.data
    -- data.session_id, data.path, data.kind, data.tool_name, data.timestamp

    -- Log all changes
    vim.notify(
      string.format("[fs-monitor] %s: %s", data.kind, data.path),
      vim.log.levels.DEBUG
    )

    -- Special handling for specific file types
    if data.path:match("%.lua$") and data.kind == "modified" then
      -- Reload Lua module if it was modified
      local module_name = data.path:gsub("lua/", ""):gsub("%.lua$", ""):gsub("/", ".")
      package.loaded[module_name] = nil
    end

    -- Track renamed files (old_path only present for renames)
    if data.kind == "renamed" and data.old_path then
      vim.notify(
        string.format("[fs-monitor] Renamed: %s -> %s", data.old_path, data.path),
        vim.log.levels.INFO
      )
    end
  end,
})
```

## Custom Diff Viewer Keymaps

Extend the diff viewer with custom actions:

```lua
local fs_monitor = require("fs-monitor")

-- Wrap show_diff to add custom behavior
local original_show_diff = fs_monitor.show_diff

fs_monitor.show_diff = function(session_id, opts)
  opts = opts or {}

  local original_on_revert = opts.on_revert
  opts.on_revert = function(changes, checkpoints)
    -- Custom post-revert action
    vim.cmd("checktime") -- Refresh all buffers

    if original_on_revert then
      original_on_revert(changes, checkpoints)
    end
  end

  return original_show_diff(session_id, opts)
end
```

## Persistent Sessions

Save and restore sessions across Neovim restarts:

```lua
local fs_monitor = require("fs-monitor")

local PersistentMonitor = {}
local cache_dir = vim.fn.stdpath("cache") .. "/fs-monitor"

function PersistentMonitor.save_session(session_id)
  local session = fs_monitor.get_session(session_id)
  if not session then return end

  vim.fn.mkdir(cache_dir, "p")

  local data = {
    id = session.id,
    changes = fs_monitor.get_changes(session_id),
    checkpoints = fs_monitor.get_checkpoints(session_id),
    metadata = session.metadata,
  }

  local file = io.open(cache_dir .. "/" .. session_id .. ".json", "w")
  if file then
    file:write(vim.fn.json_encode(data))
    file:close()
  end
end

function PersistentMonitor.restore_session(session_id)
  local filepath = cache_dir .. "/" .. session_id .. ".json"
  local file = io.open(filepath, "r")
  if not file then return nil end

  local content = file:read("*all")
  file:close()

  local data = vim.fn.json_decode(content)
  if not data then return nil end

  -- Create new session with restored data
  local session = fs_monitor.create_session({
    id = data.id,
    metadata = data.metadata,
  })

  -- Note: This restores the session state but not the file cache
  -- Changes can still be viewed but real-time monitoring needs to restart
  session.changes = data.changes
  session.checkpoints = data.checkpoints

  return session
end

return PersistentMonitor
```

## Programmatic Access to Changes

Query and filter changes programmatically:

```lua
local fs_monitor = require("fs-monitor")

-- Get all Lua files that were modified
local function get_modified_lua_files(session_id)
  local changes = fs_monitor.get_changes(session_id)
  local lua_changes = {}

  for _, change in ipairs(changes) do
    if change.path:match("%.lua$") and change.kind == "modified" then
      table.insert(lua_changes, change)
    end
  end

  return lua_changes
end

-- Get changes grouped by file
local function get_changes_by_file(session_id)
  local changes = fs_monitor.get_changes(session_id)
  local by_file = {}

  for _, change in ipairs(changes) do
    by_file[change.path] = by_file[change.path] or {}
    table.insert(by_file[change.path], change)
  end

  return by_file
end

-- Get summary statistics
local function get_summary(session_id)
  local changes = fs_monitor.get_changes(session_id)
  local summary = { created = 0, modified = 0, deleted = 0, renamed = 0 }

  for _, change in ipairs(changes) do
    summary[change.kind] = (summary[change.kind] or 0) + 1
  end

  return summary
end
```

## Configuration Reference

See `lua/fs-monitor/config.lua` for all available configuration options including:

- Monitor settings (debounce, file size limits, cache settings)
- Diff viewer geometry (window sizes, ratios)
- Icons and titles customization

Example custom configuration:

```lua
require("fs-monitor").setup({
  monitor = {
    debounce_ms = 500,
    max_file_size = 1024 * 1024, -- 1MB
    ignore_patterns = { "%.min%.js$", "%.map$" },
  },
  diff = {
    height_ratio = 0.9,
    icons = {
      created = "✚ ",
      deleted = "✖ ",
      modified = "● ",
    },
  },
})
```
