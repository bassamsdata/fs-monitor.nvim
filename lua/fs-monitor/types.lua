---@meta
-- Type definitions for fs-monitor.nvim

-- ============================================================================
-- CHANGE TYPES
-- ============================================================================

---@alias FSMonitor.Change.Kind "created"|"modified"|"deleted"|"renamed"|"transient"

---@class FSMonitor.Change.Metadata
---@field attribution? "confirmed"|"ambiguous"|"unknown" Path validation status
---@field original_tool? string Original tool name before tagging
---@field source? string Source of detection ("fs_monitor", "buffer_edit", etc)
---@field auto_detected? boolean Whether change was auto-detected
---@field all_tools? string[] All tools attributed to this change
---@field old_path? string Old path for renamed files
---@field ino? number Inode number
---@field dev? number Device ID

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
---@field cache table File path -> content cache (LRU)
---@field debounce_timer? uv.uv_timer_t Timer for debouncing events
---@field pending_events table<string, boolean> Files with pending events to process
---@field in_progress_reads table<string, number> Tracks count of in-progress async reads per path
---@field tool_name string Name of tool being monitored
---@field enabled boolean Whether this watch is active
---@field start_change_idx number Index in self.changes where this watch started

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
---@field never_ignore string[] File patterns to never ignore even if in .gitignore
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
---@field word_diff boolean Whether to enable word diff by default

---@class FSMonitor.DiffIcons
---@field created string Icon for created files
---@field deleted string Icon for deleted files
---@field modified string Icon for modified files
---@field renamed string Icon for renamed files
---@field transient string Icon for transient files
---@field checkpoint string Icon for checkpoints
---@field file_selector string Icon for file selection indicator
---@field sign string Sign column character

---@class FSMonitor.DiffTitles
---@field files string Title for files panel
---@field checkpoints string Title for checkpoints panel
---@field preview string Title for preview panel

---@alias FSMonitor.DiffKeymap FSMonitor.DiffKeymapConfig|FSMonitor.DiffKeymapFull

---@class FSMonitor.DiffKeymapConfig
---@field key string Key binding
---@field desc string Description for help menu

---@class FSMonitor.DiffKeymapFull: FSMonitor.DiffKeymapConfig
---@field callback fun() Callback function for the keymap

---@class FSMonitor.DiffKeymaps
---@field close FSMonitor.DiffKeymapConfig Close diff viewer
---@field close_alt FSMonitor.DiffKeymapConfig Alternative close binding
---@field next_file FSMonitor.DiffKeymapConfig Navigate to next file
---@field prev_file FSMonitor.DiffKeymapConfig Navigate to previous file
---@field next_file_alt FSMonitor.DiffKeymapConfig Alternative next file (j)
---@field prev_file_alt FSMonitor.DiffKeymapConfig Alternative prev file (k)
---@field next_hunk FSMonitor.DiffKeymapConfig Navigate to next hunk
---@field prev_hunk FSMonitor.DiffKeymapConfig Navigate to previous hunk
---@field goto_file FSMonitor.DiffKeymapConfig Jump to file at cursor line
---@field goto_hunk FSMonitor.DiffKeymapConfig Jump to file line from hunk
---@field goto_hunk_alt FSMonitor.DiffKeymapConfig Alternative jump to file line
---@field cycle_focus FSMonitor.DiffKeymapConfig Cycle focus between panels
---@field toggle_help FSMonitor.DiffKeymapConfig Toggle help window
---@field toggle_preview FSMonitor.DiffKeymapConfig Toggle preview only mode
---@field toggle_fullscreen FSMonitor.DiffKeymapConfig Toggle fullscreen mode
---@field reset_filter FSMonitor.DiffKeymapConfig Reset checkpoint filter
---@field view_checkpoint FSMonitor.DiffKeymapConfig View checkpoint changes
---@field view_cumulative FSMonitor.DiffKeymapConfig View accumulated changes
---@field revert_checkpoint FSMonitor.DiffKeymapConfig Revert to checkpoint
---@field revert_all FSMonitor.DiffKeymapConfig Revert all changes to original
---@field toggle_word_diff FSMonitor.DiffKeymapConfig Toggle word-level diff highlighting
---@field revert_hunk FSMonitor.DiffKeymapConfig Revert current hunk

-- ============================================================================
-- DIFF STATE & UI TYPES
-- ============================================================================

---@class FSMonitor.Diff.FileSummary
---@field changes FSMonitor.Change[]
---@field net_operation FSMonitor.Change.Kind
---@field old_path? string

---@class FSMonitor.Diff.Summary
---@field files string[] Sorted list of paths
---@field by_file table<string, FSMonitor.Diff.FileSummary>

---@class FSMonitor.Diff.Geometry
---@field row number
---@field left_col number
---@field right_col number
---@field left_w number
---@field right_w number
---@field height number
---@field files_h number
---@field checkpoints_h number
---@field checkpoints_row number
---@field gap number

---@class FSMonitor.Diff.State
---@field files_buf number
---@field files_win number
---@field checkpoints_buf number
---@field checkpoints_win number
---@field right_buf number
---@field right_win number
---@field help_buf? number
---@field help_win? number
---@field original_win? number
---@field ns number
---@field selected_file_idx number
---@field selected_checkpoint_idx? number
---@field summary FSMonitor.Diff.Summary
---@field checkpoints FSMonitor.Checkpoint[]
---@field all_changes FSMonitor.Change[]
---@field filtered_changes FSMonitor.Change[]
---@field aug? number
---@field right_keymaps? FSMonitor.DiffKeymapFull[]
---@field line_mappings? table<number, {original_line?: number, updated_line?: number, type: string}>
---@field current_filepath? string
---@field hunks? FSMonitor.Diff.Hunk[]
---@field hunk_ranges? {start_line: number, end_line: number}[]
---@field word_diff boolean
---@field is_fullscreen boolean
---@field is_preview_only boolean
---@field fs_monitor FSMonitor.Monitor
---@field generate_summary fun(changes: FSMonitor.Change[]): FSMonitor.Diff.Summary
---@field on_revert? fun(changes: FSMonitor.Change[], checkpoints: FSMonitor.Checkpoint[])
---@field get_geometry fun(is_fullscreen: boolean): FSMonitor.Diff.Geometry

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
-- RENDER TYPES
-- ============================================================================

---@class FSMonitor.Render
---@field buf number Buffer number for rendering
---@field ns number Namespace ID for extmarks
---@field lines string[] Accumulated lines to render
---@field extmarks table[] Extmarks to apply
---@field line_mappings table<number, {original_line?: number, updated_line?: number, type: string}> Maps line index to file line info
---@field hunk_ranges table[] Array of {start_line: number, end_line: number} for each hunk
---@field cfg FSMonitor.DiffConfig Diff configuration
---@field new fun(buf: number, ns: number): FSMonitor.Render Create a new render instance
---@field render_diff fun(self: FSMonitor.Render, hunks: FSMonitor.Diff.Hunk[], word_diff?: boolean): number, table, table Render the main diff view
---@field render_file_list fun(self: FSMonitor.Render, files: string[], by_file: table, selected_idx?: number) Render the file list panel
---@field render_checkpoints fun(self: FSMonitor.Render, checkpoints: FSMonitor.Checkpoint[], all_changes: FSMonitor.Change[], selected_idx?: number) Render the checkpoints panel

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
---@field max_cache_bytes number Maximum total bytes for LRU cache per watch
---@field watch_counter number Counter for generating unique watch IDs
---@field ignore_patterns string[] Compiled ignore patterns from .gitignore
---@field gitignore_loaded boolean Whether .gitignore has been loaded
---@field respect_gitignore boolean Whether to respect .gitignore
---@field custom_ignore_patterns string[] User-defined ignore patterns
---@field never_ignore_patterns string[] Patterns to never ignore even if in .gitignore
