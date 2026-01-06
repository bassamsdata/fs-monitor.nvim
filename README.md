# fs-monitor.nvim

Lightweight, real-time filesystem monitoring for Neovim. Track file changes made by AI/LLM tools during code generation sessions with checkpoint-based revert support.

Originally developed as a PR for CodeCompanion.nvim. For earlier history, see [PR #2281](https://github.com/olimorris/codecompanion.nvim/pull/2281).

## Features

- 🤝 **CodeCompanion Extension** - First-class integration for [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim)
- 🔍 **Real-time File Monitoring** - Uses OS-level file system events
- ⚡ **Async & Non-blocking** - All file I/O is asynchronous
- 📸 **Checkpoint System** - Create snapshots and revert to any previous state
- 🎨 **Diff Viewer** - Beautiful floating window diff UI with syntax highlighting
- 🔌 **Plugin Agnostic** - Works with any AI/LLM plugin via public API

## Requirements

- Neovim >= 0.11

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "bassamsdata/fs-monitor.nvim",
}
```

## CodeCompanion Integration

fs-monitor.nvim provides a CodeCompanion extension that works automatically when enabled:

```lua
require("codecompanion").setup({
  extensions = {
    fs_monitor = {
      enabled = true,
      opts = {
        keymap = "gD",
      },
    },
  },
})
```

Once enabled, fs-monitor will automatically:
- Start monitoring when you submit a chat message
- Track all file changes made by LLM tools
- Create checkpoints after each response
- Allow you to view diffs with `gD` and revert changes

## Command

```
:FSMonitor <subcommand> [args]

Subcommands:
  start [session_id]  - Start a new monitoring session
  stop [session_id]   - Stop a session
  diff [session_id]   - Show diff viewer for a session
  stats [session_id]  - Show session statistics
  help                - Show this help message
```

## Standalone Usage

You can use fs-monitor.nvim independently of CodeCompanion:

```lua
local fs_monitor = require("fs-monitor")

-- Create a monitoring session
local session = fs_monitor.create_session({ id = "my-session" })

-- Start monitoring the current directory
fs_monitor.start(session.id, vim.fn.getcwd(), {
  prepopulate = true,
  recursive = true,
})

-- ... AI/LLM makes changes to files ...

-- Create a checkpoint after changes
fs_monitor.create_checkpoint(session.id, "After first response")

-- Show the diff viewer
fs_monitor.show_diff(session.id)

-- Revert to a checkpoint
fs_monitor.revert_to_checkpoint(session.id, 1)

-- Clean up
fs_monitor.destroy_session(session.id)
```

For more integration examples (Claude Code, multi-tool tracking, event-based integration), see [docs/examples.md](docs/examples.md).

## Configuration

```lua
require("fs-monitor").setup({
  monitor = {
    debounce_ms = 300,
    max_file_size = 1024 * 1024 * 2, -- 2MB
    max_prepopulate_files = 2000,
    max_depth = 6,
    max_cache_bytes = 1024 * 1024 * 50, -- 50MB
    ignore_patterns = {},
    respect_gitignore = true,
  },
  diff = {
    -- Window geometry, icons, titles
    -- See lua/fs-monitor/config.lua for all options
  },
})
```

See [`lua/fs-monitor/config.lua`](lua/fs-monitor/config.lua) for all available configuration options.


## Diff Viewer Keymaps

| Key | Action |
|-----|--------|
| `q` / `<Esc>` | Close viewer |
| `j` / `k` | Navigate files |
| `]f` / `[f` | Next/previous file |
| `]h` / `[h` | Next/previous hunk |
| `<Tab>` | Cycle between panels |
| `<CR>` / `gf` | Jump to file at cursor line |
| `m` | Toggle preview only |
| `M` | Toggle fullscreen |
| `?` | Toggle help |
| `r` | Reset checkpoint filter |
| `R` | Revert to checkpoint |
| `X` | Revert ALL changes to original state |

## API Reference

```lua
local fs_monitor = require("fs-monitor")

-- Configuration
fs_monitor.setup(opts)

-- Session Management
fs_monitor.create_session({ id?, metadata? })
fs_monitor.get_session(session_id)
fs_monitor.destroy_session(session_id, callback?)

-- Monitoring
fs_monitor.start(session_id, target_path?, opts?)
fs_monitor.stop(session_id, callback?)

-- Changes & Checkpoints
fs_monitor.get_changes(session_id)
fs_monitor.get_checkpoints(session_id)
fs_monitor.create_checkpoint(session_id, label?)
fs_monitor.revert_to_checkpoint(session_id, idx)

-- UI
fs_monitor.show_diff(session_id, opts?)
fs_monitor.get_stats(session_id)
```

## Events

fs-monitor fires User autocmd events you can hook into:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "FSMonitorFileChanged",
  callback = function(event)
    local data = event.data
    -- data.session_id, data.path, data.kind, data.tool_name, data.timestamp
    -- data.old_path (for renames only)
  end,
})
```

| Event | Data |
|-------|------|
| `FSMonitorStarted` | `{ session_id, target_path, watch_id, prepopulate, recursive }` |
| `FSMonitorStopped` | `{ session_id, watch_id, change_count, total_changes }` |
| `FSMonitorCheckpoint` | `{ session_id, checkpoint_index, label, change_count, timestamp }` |
| `FSMonitorFileChanged` | `{ session_id, path, kind, tool_name, timestamp, old_path? }` |

## License

Apache 2.0

## Acknowledgements

Developed as a PR to be part of [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim), extracted into a standalone plugin.
