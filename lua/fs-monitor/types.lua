---@meta
-- Type definitions for fs-monitor.nvim

-- ============================================================================
-- CHANGE TYPES
-- ============================================================================

---@alias FSMonitor.Change.Kind "created"|"modified"|"deleted"|"renamed"

---@class FSMonitor.Change.Metadata
---@field attribution? "confirmed"|"ambiguous"|"unknown" Path validation status
---@field original_tool? string Original tool name before tagging
---@field source? string Source of detection ("fs_monitor", "buffer_edit", etc)
---@field auto_detected? boolean Whether change was auto-detected
---@field all_tools? string[] All tools attributed to this change
---@field old_path? string Old path for renamed files

---@class FSMonitor.Change
---@field path string Relative file path
---@field kind FSMonitor.Change.Kind Type of change
---@field old_content? string Content before change (nil for created)
---@field new_content? string Content after change (nil for deleted)
---@field timestamp number High-resolution timestamp (nanoseconds from vim.uv.hrtime)
---@field tool_name string Original tool name from watch (may be "workspace")
---@field tools? string[] Array of tools that caused this change (set via tagging)
---@field metadata FSMonitor.Change.Metadata Additional info

-- ============================================================================
-- CHECKPOINT TYPES
-- ============================================================================

---@class FSMonitor.Checkpoint
---@field timestamp number High-resolution timestamp (nanoseconds)
---@field change_count number Number of changes at checkpoint time
---@field cycle? number Chat cycle number when checkpoint was created
---@field label? string Human-readable label for the checkpoint

-- ============================================================================
-- STATS TYPES
-- ============================================================================

---@class FSMonitor.PrepopulateStats
---@field files_scanned number Total files encountered
---@field files_cached number Files successfully cached
---@field bytes_cached number Total bytes cached
---@field errors number Number of errors
---@field directories_scanned number Directories traversed
---@field elapsed_ms number Time taken in milliseconds

-- ============================================================================
-- WATCH TYPES
-- ============================================================================

---@class FSMonitor.Watch
---@field handle uv.uv_fs_event_t|nil FS event handle
---@field root_path string Root directory being watched
---@field cache table<string, string> File path -> content cache
---@field debounce_timer? uv.uv_timer_t Timer for debouncing events
---@field pending_events table<string, boolean> Files with pending events to process
---@field tool_name string Name of tool being monitored (e.g., "workspace", "edit_tool_exp")
---@field enabled boolean Whether this watch is active

-- ============================================================================
-- MONITOR CONFIGURATION
-- ============================================================================

---@class FSMonitor.Config
---@field debounce_ms number Debounce delay in milliseconds
---@field max_file_size number Maximum file size to track in bytes
---@field max_prepopulate_files number Maximum files to cache on start
---@field max_depth number Maximum directory depth for recursive scanning
---@field max_cache_bytes number Maximum total bytes for LRU cache
---@field ignore_patterns string[] Additional patterns to ignore
---@field respect_gitignore boolean Whether to respect .gitignore
---@field debug boolean Enable debug logging
---@field debug_file? string Path to debug log file

-- ============================================================================
-- DIFF VIEWER CONFIGURATION
-- ============================================================================

---@class FSMonitor.DiffConfig
---@field min_height number Minimum window height
---@field min_left_width number Minimum left panel width
---@field min_right_width number Minimum right panel width
---@field left_width_ratio number Left panel width ratio (0-1)
---@field right_width_ratio number Right panel width ratio (0-1)
---@field height_ratio number Window height ratio (0-1)
---@field checkpoints_height_ratio number Checkpoints panel height ratio (0-1)
---@field gap number Gap between panels
---@field left_gap number Gap between left panels
---@field zindex number Z-index for floating windows
---@field help_zindex number Z-index for help window
---@field icons FSMonitor.DiffIcons Icon configuration
---@field titles FSMonitor.DiffTitles Window title configuration
---@field keymaps FSMonitor.DiffKeymaps Keymap configuration

---@class FSMonitor.DiffIcons
---@field created string Icon for created files
---@field deleted string Icon for deleted files
---@field modified string Icon for modified files
---@field renamed string Icon for renamed files
---@field checkpoint string Icon for checkpoints
---@field file_selector string Icon for file selection indicator
---@field sign string Sign column character
---@field title_created string Title icon for created files
---@field title_deleted string Title icon for deleted files
---@field title_modified string Title icon for modified files
---@field title_renamed string Title icon for renamed files

---@class FSMonitor.DiffTitles
---@field files string Title for files panel
---@field checkpoints string Title for checkpoints panel
---@field preview string Title for preview panel

---@class FSMonitor.DiffKeymap
---@field key string Key binding
---@field desc string Description for help menu

---@class FSMonitor.DiffKeymaps
---@field close FSMonitor.DiffKeymap Close diff viewer
---@field close_alt FSMonitor.DiffKeymap Alternative close binding
---@field next_file FSMonitor.DiffKeymap Navigate to next file
---@field prev_file FSMonitor.DiffKeymap Navigate to previous file
---@field next_file_alt FSMonitor.DiffKeymap Alternative next file (j)
---@field prev_file_alt FSMonitor.DiffKeymap Alternative prev file (k)
---@field next_hunk FSMonitor.DiffKeymap Navigate to next hunk
---@field prev_hunk FSMonitor.DiffKeymap Navigate to previous hunk
---@field goto_file FSMonitor.DiffKeymap Jump to file at cursor line
---@field goto_file_alt FSMonitor.DiffKeymap Alternative goto file (Enter)
---@field cycle_focus FSMonitor.DiffKeymap Cycle focus between panels
---@field toggle_help FSMonitor.DiffKeymap Toggle help window
---@field toggle_preview FSMonitor.DiffKeymap Toggle preview only mode
---@field toggle_fullscreen FSMonitor.DiffKeymap Toggle fullscreen mode
---@field reset_filter FSMonitor.DiffKeymap Reset checkpoint filter
---@field view_checkpoint FSMonitor.DiffKeymap View checkpoint changes
---@field view_cumulative FSMonitor.DiffKeymap View accumulated changes
---@field revert_checkpoint FSMonitor.DiffKeymap Revert to checkpoint
---@field revert_all FSMonitor.DiffKeymap Revert all changes to original

-- ============================================================================
-- DIFF HUNK TYPES
-- ============================================================================

---@class FSMonitor.Diff.Hunk
---@field original_start number Starting line in original content
---@field original_count number Number of lines in original
---@field updated_start number Starting line in updated content
---@field updated_count number Number of lines in updated
---@field removed_lines string[] Lines removed
---@field added_lines string[] Lines added
---@field context_before string[] Context lines before the change
---@field context_after string[] Context lines after the change

-- ============================================================================
-- SESSION TYPES
-- ============================================================================

---@class FSMonitor.Session
---@field id string Unique session identifier
---@field monitor FSMonitor.Monitor The monitor instance
---@field changes FSMonitor.Change[] Accumulated changes
---@field checkpoints FSMonitor.Checkpoint[] Checkpoints created during session
---@field watch_id? string Active watch ID
---@field started_at number Session start timestamp
---@field metadata table User-defined metadata

-- ============================================================================
-- MONITOR CLASS
-- ============================================================================

---@class FSMonitor.Monitor
---@field session_id string Session identifier
---@field watches table<string, FSMonitor.Watch> Active watches by watch_id
---@field changes FSMonitor.Change[] Accumulated changes across all watches
---@field debounce_ms number Debounce delay in milliseconds
---@field max_file_size number Maximum file size to track (bytes)
---@field max_prepopulate_files number Maximum files to cache on prepopulate
---@field max_depth number Maximum directory depth for recursive scanning
---@field watch_counter number Counter for generating unique watch IDs
---@field ignore_patterns string[] Compiled ignore patterns from .gitignore
---@field gitignore_loaded boolean Whether .gitignore has been loaded
---@field content_cache table<string, string> Global content cache
---@field respect_gitignore boolean Whether to respect .gitignore
---@field custom_ignore_patterns string[] User-defined ignore patterns
