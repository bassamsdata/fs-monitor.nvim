---@module "fs-monitor.types"
--[[
File System Monitor - Event-based file change tracking

This module tracks file changes in real-time using OS-level file system events.
Unlike snapshot-based approaches, it monitors actual file system notifications
and maintains a content cache for efficient diffing.

Architecture:
- Uses vim.uv.new_fs_event() for OS-level file watching
- Async file I/O with vim.uv.fs_* functions (never blocks Neovim)
- Debounced event processing to handle rapid changes
- Content cache with "insert returns old" pattern for easy diffing

Key Design:
- Changes are registered via async file reads (non-blocking)
- stop_monitoring_async() waits for all pending operations before calling back
- Uses uv.fs_opendir/readdir for efficient directory scanning
- Timestamp-based attribution links changes to specific tools
- Respects .gitignore patterns for intelligent file filtering

API Overview:
  Core Monitoring:
    - start_monitoring(tool_name, target_path, opts) -> watch_id
    - stop_monitoring_async(watch_id, callback)
    - tag_changes_in_range(start_time, end_time, tool_name, tool_args)

  Checkpoints:
    - create_checkpoint() -> checkpoint
    - get_changes_since_checkpoint(checkpoint) -> Change[]

  Change Retrieval:
    - get_all_changes() -> Change[]
    - get_changes_by_tool(tool_name) -> Change[]
    - get_stats() -> stats
    - clear_changes()
]]

local uv = vim.uv
local lru = require("fs-monitor.utils.lru")
local gitignore = require("fs-monitor.utils.gitignore")
local log = require("fs-monitor.log")

local fmt = string.format

---@class FSMonitor.Monitor
local FSMonitor = {}
FSMonitor.__index = FSMonitor

-- Default constants
local DEFAULT_DEBOUNCE_MS = 300
local DEFAULT_MAX_FILE_SIZE = 1024 * 1024 * 2 -- 2MB
local DEFAULT_MAX_PREPOPULATE_FILES = 2000
local DEFAULT_MAX_DEPTH = 6
local DEFAULT_MAX_CACHE_BYTES = 1024 * 1024 * 50 -- 50MB total cache limit
local RENAME_DETECTION_WINDOW = 2000000000 -- 2seconds

---Create a new FSMonitor instance
---@param opts? { session_id?: string, debounce_ms?: number, max_file_size?: number, max_prepopulate_files?: number, max_depth?: number, max_cache_bytes?: number, ignore_patterns?: string[], respect_gitignore?: boolean, never_ignore?: string[] }
---@return FSMonitor.Monitor
function FSMonitor.new(opts)
  opts = opts or {}

  local max_cache_bytes = opts.max_cache_bytes or DEFAULT_MAX_CACHE_BYTES

  local monitor = setmetatable({
    session_id = opts.session_id or "default",
    watches = {},
    changes = {},
    content_cache = lru.create(max_cache_bytes),
    debounce_ms = opts.debounce_ms or DEFAULT_DEBOUNCE_MS,
    max_file_size = opts.max_file_size or DEFAULT_MAX_FILE_SIZE,
    max_prepopulate_files = opts.max_prepopulate_files or DEFAULT_MAX_PREPOPULATE_FILES,
    max_depth = opts.max_depth or DEFAULT_MAX_DEPTH,
    max_cache_bytes = max_cache_bytes,
    watch_counter = 0,
    ignore_patterns = {},
    gitignore_loaded = false,
    respect_gitignore = opts.respect_gitignore ~= false,
    custom_ignore_patterns = opts.ignore_patterns or {},
    never_ignore_patterns = opts.never_ignore or {},
  }, FSMonitor)

  -- gitignore patterns will be loaded when monitoring starts
  -- to use the correct watch root path

  log:debug("Created monitor session: %s", monitor.session_id)
  return monitor
end

---Generate a unique watch ID
---@param tool_name string
---@param root_path string
---@return string
function FSMonitor:_generate_watch_id(tool_name, root_path)
  self.watch_counter = self.watch_counter + 1
  return fmt("%s:%s:%d", tool_name, root_path, self.watch_counter)
end

---Get relative path from root
---@param path string
---@param root_path string
---@return string Relative path
function FSMonitor:_get_relative_path(path, root_path)
  local normalized_file = vim.fs.normalize(path)
  local normalized_root = vim.fs.normalize(root_path)

  if normalized_file:sub(1, #normalized_root) == normalized_root then
    local relative = normalized_file:sub(#normalized_root + 1)
    if relative:sub(1, 1) == "/" or relative:sub(1, 1) == "\\" then relative = relative:sub(2) end
    return relative
  end

  return normalized_file
end

---Load .gitignore patterns from a directory
---@param root_path? string Directory to load .gitignore from (defaults to cwd)
function FSMonitor:_load_gitignore(root_path)
  root_path = root_path or vim.fn.getcwd()

  self._gitignore_roots = self._gitignore_roots or {}
  if self._gitignore_roots[root_path] then return end
  self._gitignore_roots[root_path] = true

  local gitignore_path = vim.fs.joinpath(root_path, ".gitignore")
  local patterns = gitignore.load_patterns(gitignore_path)

  for _, parsed in ipairs(patterns) do
    table.insert(self.ignore_patterns, parsed)
  end

  self.gitignore_loaded = true
end

---Load gitignore for a specific watch root (called when starting monitoring)
---@param watch_root string The root path being watched
function FSMonitor:_ensure_gitignore_loaded(watch_root)
  if self.respect_gitignore then self:_load_gitignore(watch_root) end
end

---Check if file should be ignored based on patterns
---@param filepath string
---@return boolean should_ignore
function FSMonitor:_should_ignore_file(filepath)
  -- First check if file matches never_ignore patterns
  for _, pattern in ipairs(self.never_ignore_patterns) do
    if filepath:match(pattern) or filepath == pattern then
      return false -- Never ignore this file
    end
  end

  -- Then check gitignore and custom ignore patterns
  return gitignore.should_ignore(filepath, self.ignore_patterns, self.custom_ignore_patterns)
end

---Check if content appears to be binary
---@param content string
---@return boolean is_binary
local function is_binary_content(content)
  if not content or #content == 0 then return false end
  -- Check first 8KB for null bytes (common binary indicator)
  local check_len = math.min(#content, 8192)
  local sample = content:sub(1, check_len)
  return sample:find("\0") ~= nil
end

---Read file content asynchronously
---@param filepath string
---@param callback fun(content: string|nil, err: string|nil, stat?: table)
function FSMonitor:_read_file_async(filepath, callback)
  uv.fs_open(filepath, "r", 438, function(err_open, fd)
    if err_open then return callback(nil, err_open) end

    if not fd then return callback(nil, "Failed to open file") end

    uv.fs_fstat(fd, function(err_stat, stat)
      if err_stat then
        uv.fs_close(fd)
        return callback(nil, err_stat)
      end

      if not stat then
        uv.fs_close(fd)
        return callback(nil, "Failed to get file stats")
      end

      if stat.size > self.max_file_size then
        uv.fs_close(fd)
        return callback(nil, fmt("File too large: %d bytes", stat.size))
      end

      if stat.size == 0 then
        uv.fs_close(fd)
        return callback("", nil)
      end

      uv.fs_read(fd, stat.size, 0, function(err_read, data)
        uv.fs_close(fd)

        if err_read then return callback(nil, err_read, nil) end
        if data and is_binary_content(data) then return callback(nil, "Binary file", nil) end

        callback(data or "", nil, { ino = stat.ino, dev = stat.dev })
      end)
    end)
  end)
end

---Simple hash for content comparison (first + last 1KB + length)
---@param content string
---@return string hash
local function content_hash(content)
  if not content or #content == 0 then return "empty" end
  local len = #content
  local first = content:sub(1, 1024)
  local last = len > 1024 and content:sub(-1024) or ""
  return fmt("%d:%s:%s", len, first, last)
end

---Check if a created file is a rename by matching inode
---@param self FSMonitor.Monitor
---@param new_change FSMonitor.Change
---@return FSMonitor.Change|nil deleted_change The matching deleted change, or nil
local function _detect_rename_by_inode(self, new_change)
  local ino = new_change.metadata and new_change.metadata.ino
  local dev = new_change.metadata and new_change.metadata.dev
  if not ino or not dev then return nil end

  for i = #self.changes, 1, -1 do
    local existing = self.changes[i]

    if
      existing.kind == "deleted"
      and existing.metadata
      and existing.metadata.ino == ino
      and existing.metadata.dev == dev
    then
      return existing
    end
  end

  return nil
end

---Check if a created file is a rename by matching content hash
---@param self FSMonitor.Monitor
---@param new_change FSMonitor.Change
---@return FSMonitor.Change|nil deleted_change The matching deleted change, or nil
local function _detect_rename_by_hash(self, new_change)
  if not new_change.new_content then return nil end

  local new_hash = content_hash(new_change.new_content)
  local current_time = new_change.timestamp

  for i = #self.changes, 1, -1 do
    local existing = self.changes[i]

    local time_diff = current_time - existing.timestamp
    if time_diff > RENAME_DETECTION_WINDOW then break end

    if existing.kind == "deleted" and existing.old_content then
      local old_hash = content_hash(existing.old_content)
      if old_hash == new_hash then return existing end
    end
  end

  return nil
end

---Check if a created file might be a rename of a recently deleted file
---@param self FSMonitor.Monitor
---@param new_change FSMonitor.Change
---@return FSMonitor.Change|nil deleted_change The matching deleted change, or nil
local function _detect_rename(self, new_change)
  if new_change.kind ~= "created" then return nil end

  local inode_match = _detect_rename_by_inode(self, new_change)
  if inode_match then return inode_match end

  return _detect_rename_by_hash(self, new_change)
end

---Register a change in the changes list
---@param change FSMonitor.Change
function FSMonitor:_register_change(change)
  -- Check for duplicate changes (same file, same kind, within 1 second)
  local current_time = change.timestamp
  local duplicate = false

  for i = #self.changes, 1, -1 do
    local existing = self.changes[i]
    if existing.path == change.path and existing.kind == change.kind then
      local time_diff = current_time - existing.timestamp
      if time_diff < 1000000000 then
        duplicate = true
        break
      end
      if time_diff > 5000000000 then -- 5 seconds
        break
      end
    end
  end

  if duplicate then return end

  local deleted_match = _detect_rename(self, change)
  if deleted_match then
    -- Convert delete + create into a rename
    -- Remove the deleted change from the list
    for i = #self.changes, 1, -1 do
      if self.changes[i] == deleted_match then
        table.remove(self.changes, i)
        break
      end
    end

    change = {
      path = change.path,
      kind = "renamed",
      old_content = deleted_match.old_content,
      new_content = change.new_content,
      timestamp = change.timestamp,
      tool_name = change.tool_name,
      metadata = {
        old_path = deleted_match.path,
        new_path = change.path,
      },
    }

    vim.api.nvim_exec_autocmds("User", {
      pattern = "FSMonitorFileChanged",
      data = {
        session_id = self.session_id,
        path = change.path,
        kind = "renamed",
        tool_name = change.tool_name,
        timestamp = change.timestamp,
        old_path = deleted_match.path,
      },
    })

    table.insert(self.changes, change)
    return
  end

  table.insert(self.changes, change)

  vim.api.nvim_exec_autocmds("User", {
    pattern = "FSMonitorFileChanged",
    data = {
      session_id = self.session_id,
      path = change.path,
      kind = change.kind,
      tool_name = change.tool_name,
      timestamp = change.timestamp,
    },
  })
end

---Process a single file change
---@param watch_id string
---@param path string Full path to changed file
---@param on_complete? fun() Optional callback when processing is done
function FSMonitor:_process_file_change(watch_id, path, on_complete)
  local watch = self.watches[watch_id]
  if not watch or not watch.enabled then
    if on_complete then on_complete() end
    return
  end

  if self:_should_ignore_file(path) then
    if on_complete then on_complete() end
    return
  end

  local relative_path = self:_get_relative_path(path, watch.root_path)
  local cached_content = lru.get(watch.cache, relative_path)

  self:_read_file_async(path, function(new_content, err, stat)
    vim.schedule(function()
      if not self.watches[watch_id] or not self.watches[watch_id].enabled then return end

      if err and (err:match("ENOENT") or err:match("no such file")) then
        if cached_content then
          lru.remove(watch.cache, relative_path)
          self:_register_change({
            path = relative_path,
            kind = "deleted",
            old_content = cached_content,
            new_content = nil,
            timestamp = uv.hrtime(),
            tool_name = watch.tool_name,
            metadata = {
              ino = stat and stat.ino,
              dev = stat and stat.dev,
            },
          })
        end
        if on_complete then on_complete() end
        return
      end

      if err then
        if on_complete then on_complete() end
        return
      end

      local should_cache = false
      if cached_content then
        if cached_content ~= new_content then
          should_cache = true
          self:_register_change({
            path = relative_path,
            kind = "modified",
            old_content = cached_content,
            new_content = new_content,
            timestamp = uv.hrtime(),
            tool_name = watch.tool_name,
            metadata = {
              old_size = #cached_content,
              new_size = #new_content,
              ino = stat and stat.ino,
              dev = stat and stat.dev,
            },
          })
        end
      else
        should_cache = true
        self:_register_change({
          path = relative_path,
          kind = "created",
          old_content = nil,
          new_content = new_content,
          timestamp = uv.hrtime(),
          tool_name = watch.tool_name,
          metadata = {
            size = #new_content,
            ino = stat and stat.ino,
            dev = stat and stat.dev,
          },
        })
      end

      if should_cache and new_content then lru.set(watch.cache, relative_path, new_content) end

      if on_complete then on_complete() end
    end)
  end)
end

---Handle a file system event
---@param watch_id string
---@param filename string Relative filename that changed
function FSMonitor:_handle_fs_event(watch_id, filename)
  local watch = self.watches[watch_id]
  if not watch or not watch.enabled then return end

  local full_path = vim.fs.joinpath(watch.root_path, filename)

  watch.pending_events[full_path] = true

  if watch.debounce_timer then
    watch.debounce_timer:stop()
  else
    watch.debounce_timer = uv.new_timer()
  end

  watch.debounce_timer:start(self.debounce_ms, 0, function()
    vim.schedule(function()
      if not self.watches[watch_id] or not self.watches[watch_id].enabled then return end

      local pending = vim.tbl_keys(watch.pending_events)
      watch.pending_events = {}

      for _, path in ipairs(pending) do
        self:_process_file_change(watch_id, path)
      end
    end)
  end)
end

---Prepopulate cache with existing file contents
---@param watch FSMonitor.Watch Watch structure
---@param target_path string File or directory path
---@param is_dir boolean
---@param on_complete? fun(stats: FSMonitor.PrepopulateStats)
function FSMonitor:_prepopulate_cache(watch, target_path, is_dir, on_complete)
  local start_time = uv.hrtime()
  local stats = {
    files_scanned = 0,
    files_cached = 0,
    bytes_cached = 0,
    errors = 0,
    directories_scanned = 0,
    elapsed_ms = 0,
  }

  -- Track pending async operations
  local pending = 1

  local function done()
    pending = pending - 1
    if pending == 0 then
      stats.elapsed_ms = (uv.hrtime() - start_time) / 1000000
      if on_complete then vim.schedule(function()
        on_complete(stats)
      end) end
    end
  end

  if not is_dir then
    local relative_path = self:_get_relative_path(target_path, watch.root_path)
    self:_read_file_async(target_path, function(content, err)
      vim.schedule(function()
        if not err and content then
          watch.cache[relative_path] = content
          stats.files_cached = 1
          stats.bytes_cached = #content
        else
          stats.errors = 1
        end
        done()
      end)
    end)
    return
  end

  local count = { value = 0 }

  local function scan_dir(dir, depth)
    if count.value >= self.max_prepopulate_files or depth > self.max_depth then
      done()
      return
    end

    stats.directories_scanned = stats.directories_scanned + 1

    uv.fs_opendir(dir, function(err_open, dir_handle)
      if err_open or not dir_handle then
        stats.errors = stats.errors + 1
        done()
        return
      end

      local function read_batch()
        dir_handle:readdir(function(err_read, entries)
          if err_read then
            stats.errors = stats.errors + 1
            dir_handle:closedir()
            done()
            return
          end

          if not entries then
            dir_handle:closedir()
            done()
            return
          end

          for _, entry in ipairs(entries) do
            if count.value >= self.max_prepopulate_files then
              dir_handle:closedir()
              done()
              return
            end

            local full_path = vim.fs.joinpath(dir, entry.name)
            is_dir = entry.type == "directory"

            if not self:_should_ignore_file(full_path) then
              if entry.type == "file" then
                stats.files_scanned = stats.files_scanned + 1
                local relative_path = self:_get_relative_path(full_path, watch.root_path)

                pending = pending + 1

                self:_read_file_async(full_path, function(content, read_err)
                  vim.schedule(function()
                    if not read_err and content then
                      lru.set(watch.cache, relative_path, content)
                      stats.files_cached = stats.files_cached + 1
                      stats.bytes_cached = stats.bytes_cached + #content
                    else
                      stats.errors = stats.errors + 1
                    end
                    done()
                  end)
                end)

                count.value = count.value + 1
              elseif entry.type == "directory" then
                pending = pending + 1
                scan_dir(full_path, depth + 1)
              end
            end
          end

          read_batch()
        end)
      end

      read_batch()
    end)
  end

  scan_dir(target_path, 0)
end

---Start monitoring a file or directory for changes
---@param tool_name string
---@param target_path string File or directory to watch
---@param opts? table Options: { prepopulate = true, recursive = false, on_ready = function(stats) }
---@return string watch_id
function FSMonitor:start_monitoring(tool_name, target_path, opts)
  opts = opts or {}
  local prepopulate = opts.prepopulate ~= false -- Default true
  local recursive = opts.recursive or false
  local on_ready = opts.on_ready

  local normalized_path = vim.fs.normalize(target_path)
  local stat = uv.fs_stat(normalized_path)

  if not stat then return "" end

  local is_dir = stat.type == "directory"
  local root_path = is_dir and normalized_path or vim.fs.dirname(normalized_path)

  self:_ensure_gitignore_loaded(root_path)

  for existing_watch_id, watch in pairs(self.watches) do
    if watch.root_path == root_path and watch.enabled then return existing_watch_id end
  end

  local watch_id = self:_generate_watch_id(tool_name, root_path)
  log:debug("Starting monitoring: %s at %s", watch_id, root_path)

  self.watches[watch_id] = {
    handle = nil,
    root_path = root_path,
    cache = lru.create(self.max_cache_bytes),
    debounce_timer = nil,
    pending_events = {},
    tool_name = tool_name,
    enabled = true,
    start_change_idx = #self.changes,
  }

  local watch = self.watches[watch_id]

  if prepopulate then self:_prepopulate_cache(watch, normalized_path, is_dir, on_ready) end

  watch.handle = uv.new_fs_event()
  if not watch.handle then
    self.watches[watch_id] = nil
    return ""
  end

  local ok = watch.handle:start(root_path, { recursive = recursive }, function(err_event, filename)
    if err_event then return end

    if filename then self:_handle_fs_event(watch_id, filename) end
  end)

  if not ok then
    if watch.handle and not watch.handle:is_closing() then watch.handle:close() end
    self.watches[watch_id] = nil
    return ""
  end

  log:debug("Monitoring started: %s", watch_id)
  return watch_id
end

---Clean up a watch's resources to prevent memory leaks
---@param watch FSMonitor.Watch
local function cleanup_watch(watch)
  if watch.debounce_timer then
    watch.debounce_timer:stop()
    if not watch.debounce_timer:is_closing() then watch.debounce_timer:close() end
    watch.debounce_timer = nil
  end

  if watch.handle then
    watch.handle:stop()
    if not watch.handle:is_closing() then watch.handle:close() end
    watch.handle = nil
  end

  if watch.cache then
    lru.clear(watch.cache)
    watch.cache = nil
  end
  watch.pending_events = nil
end

---Stop monitoring and return changes via callback
---@param watch_id string
---@param callback fun(changes: FSMonitor.Change[])
function FSMonitor:stop_monitoring_async(watch_id, callback)
  local watch = self.watches[watch_id]
  if not watch then return callback({}) end

  watch.enabled = false
  log:debug("Stopping monitoring: %s", watch_id)

  local pending_paths = vim.tbl_keys(watch.pending_events or {})
  local watch_cache = watch.cache
  local watch_root = watch.root_path
  local watch_tool = watch.tool_name
  local start_idx = watch.start_change_idx

  -- Helper to get changes from this monitoring session only
  local function get_session_changes()
    local session_changes = {}
    for i = start_idx + 1, #self.changes do
      table.insert(session_changes, self.changes[i])
    end
    return session_changes
  end

  if #pending_paths == 0 then
    local session_changes = get_session_changes()
    cleanup_watch(watch)
    self.watches[watch_id] = nil
    return callback(session_changes)
  end

  -- Stop timers and handles but keep cache for pending reads
  if watch.debounce_timer then
    watch.debounce_timer:stop()
    if not watch.debounce_timer:is_closing() then watch.debounce_timer:close() end
    watch.debounce_timer = nil
  end

  if watch.handle then
    watch.handle:stop()
    if not watch.handle:is_closing() then watch.handle:close() end
    watch.handle = nil
  end

  local remaining = #pending_paths
  local completed = false

  local function on_file_processed()
    remaining = remaining - 1

    if remaining == 0 and not completed then
      completed = true
      local session_changes = get_session_changes()
      -- Final cleanup - clear remaining cache
      watch.cache = nil
      watch.pending_events = nil
      self.watches[watch_id] = nil
      callback(session_changes)
    end
  end

  for _, path in ipairs(pending_paths) do
    local relative_path = self:_get_relative_path(path, watch_root)
    local cached_content = watch_cache and lru.get(watch_cache, relative_path)

    self:_read_file_async(path, function(content, err)
      vim.schedule(function()
        if err and (err:match("ENOENT") or err:match("no such file")) then
          if cached_content then
            self:_register_change({
              path = relative_path,
              kind = "deleted",
              old_content = cached_content,
              new_content = nil,
              timestamp = uv.hrtime(),
              tool_name = watch_tool,
              metadata = {},
            })
          end
        elseif not err and content then
          if cached_content and cached_content ~= content then
            self:_register_change({
              path = relative_path,
              kind = "modified",
              old_content = cached_content,
              new_content = content,
              timestamp = uv.hrtime(),
              tool_name = watch_tool,
              metadata = {
                old_size = #cached_content,
                new_size = #content,
              },
            })
          elseif not cached_content then
            self:_register_change({
              path = relative_path,
              kind = "created",
              old_content = nil,
              new_content = content,
              timestamp = uv.hrtime(),
              tool_name = watch_tool,
              metadata = {
                size = #content,
              },
            })
          end
        end

        on_file_processed()
      end)
    end)
  end
end

---Stop all active watches
---@param callback fun() Called when all watches are stopped
function FSMonitor:stop_all_async(callback)
  local watch_ids = vim.tbl_keys(self.watches)
  if #watch_ids == 0 then
    self.content_cache = {}
    return callback()
  end

  local remaining = #watch_ids
  for _, watch_id in ipairs(watch_ids) do
    self:stop_monitoring_async(watch_id, function()
      remaining = remaining - 1
      if remaining == 0 then
        self.content_cache = {}
        callback()
      end
    end)
  end
end

---Get all changes detected across all watches
---@return FSMonitor.Change[] changes
function FSMonitor:get_all_changes()
  return vim.deepcopy(self.changes)
end

---Flush all pending events and return changes
---This ensures all pending FS events are processed before returning
---@param callback fun(changes: FSMonitor.Change[])
function FSMonitor:flush_pending_and_get_changes(callback)
  local all_pending = {}

  for watch_id, watch in pairs(self.watches) do
    if watch.enabled then
      if watch.debounce_timer then watch.debounce_timer:stop() end
      for path, _ in pairs(watch.pending_events or {}) do
        table.insert(all_pending, { watch_id = watch_id, path = path })
      end
      watch.pending_events = {}
    end
  end

  if #all_pending == 0 then return callback(vim.deepcopy(self.changes)) end

  local remaining = #all_pending
  for _, item in ipairs(all_pending) do
    self:_process_file_change(item.watch_id, item.path, function()
      remaining = remaining - 1
      if remaining == 0 then callback(vim.deepcopy(self.changes)) end
    end)
  end
end

---Set/replace the changes list (used after revert)
---@param new_changes FSMonitor.Change[]
function FSMonitor:set_changes(new_changes)
  self.changes = vim.deepcopy(new_changes)

  -- Rebuild content_cache to only include files that have changes
  local files_with_changes = {}
  for _, change in ipairs(new_changes) do
    files_with_changes[change.path] = true
  end

  for path, _ in pairs(self.content_cache) do
    if not files_with_changes[path] then self.content_cache[path] = nil end
  end
end

---Get changes for a specific tool
---@param tool_name string
---@return FSMonitor.Change[] changes
function FSMonitor:get_changes_by_tool(tool_name)
  local tool_changes = {}
  for _, change in ipairs(self.changes) do
    if change.tool_name == tool_name then table.insert(tool_changes, change) end
  end
  return tool_changes
end

---Clear all tracked changes
function FSMonitor:clear_changes()
  self.changes = {}
end

---Create a checkpoint for resuming monitoring
---@return FSMonitor.Checkpoint
function FSMonitor:create_checkpoint()
  local checkpoint = {
    timestamp = uv.hrtime(),
    change_count = #self.changes,
  }
  return checkpoint
end

---Get changes since a checkpoint
---@param checkpoint FSMonitor.Checkpoint
---@return FSMonitor.Change[]
function FSMonitor:get_changes_since_checkpoint(checkpoint)
  local changes = {}
  for i = checkpoint.change_count + 1, #self.changes do
    table.insert(changes, self.changes[i])
  end
  return changes
end

---Get statistics about tracked changes
---@return table stats
function FSMonitor:get_stats()
  local stats = {
    total_changes = #self.changes,
    created = 0,
    modified = 0,
    deleted = 0,
    renamed = 0,
    tools = {},
    active_watches = vim.tbl_count(self.watches),
  }

  for _, change in ipairs(self.changes) do
    if change.kind == "created" then
      stats.created = stats.created + 1
    elseif change.kind == "modified" then
      stats.modified = stats.modified + 1
    elseif change.kind == "deleted" then
      stats.deleted = stats.deleted + 1
    elseif change.kind == "renamed" then
      stats.renamed = stats.renamed + 1
    end

    if not vim.tbl_contains(stats.tools, change.tool_name) then table.insert(stats.tools, change.tool_name) end
  end

  return stats
end

---Tag changes in a time range with a tool name and validate against tool paths
---@param start_time number
---@param end_time number
---@param tool_name string
---@param tool_args? table
function FSMonitor:tag_changes_in_range(start_time, end_time, tool_name, tool_args)
  tool_args = tool_args or {}

  -- Extract expected paths from tool args
  local expected_paths = {}
  if tool_args.filepath then
    local normalized = vim.fs.normalize(tool_args.filepath)
    local relative = self:_get_relative_path(normalized, vim.fn.getcwd())
    table.insert(expected_paths, relative)
  end

  for _, change in ipairs(self.changes) do
    if change.timestamp >= start_time and change.timestamp <= end_time then
      if not change.tools then
        change.tools = {}
        change.metadata = change.metadata or {}
        change.metadata.original_tool = change.tool_name
      end

      -- Check if this change matches the tool's declared paths
      local matches_declared_path = false
      if #expected_paths > 0 then
        for _, expected_path in ipairs(expected_paths) do
          if change.path == expected_path or change.path:match("^" .. vim.pesc(expected_path)) then
            matches_declared_path = true
            break
          end
        end
      else
        -- Tool didn't declare a filepath - assume it safe only tool (eg grep_search)
        matches_declared_path = true
      end

      if not vim.tbl_contains(change.tools, tool_name) then table.insert(change.tools, tool_name) end

      if matches_declared_path then
        change.metadata.attribution = "confirmed"
      else
        change.metadata.attribution = "ambiguous"
      end
    end
  end
end

---Safely delete a file with error handling
---@param filepath string
---@return boolean success
---@return string|nil error
local function safe_delete_file(filepath)
  local ok, err = pcall(function()
    local stat = uv.fs_stat(filepath)
    if stat then os.remove(filepath) end
  end)
  if not ok then return false, tostring(err) end
  return true, nil
end

---Safely write content to a file with error handling
---@param filepath string
---@param content string
---@return boolean success
---@return string|nil error
local function safe_write_file(filepath, content)
  local ok, err = pcall(function()
    -- Ensure parent directory exists
    local parent_dir = vim.fs.dirname(filepath)
    if parent_dir and parent_dir ~= "" then vim.fn.mkdir(parent_dir, "p") end

    local fd = uv.fs_open(filepath, "w", 438)
    if not fd then error("Failed to open file for writing") end

    local write_ok, write_err = uv.fs_write(fd, content, 0)
    uv.fs_close(fd)

    if not write_ok then error(write_err or "Failed to write file") end
  end)

  if not ok then return false, tostring(err) end
  return true, nil
end

---Revert files to state at a checkpoint
---R on checkpoint N: Revert to state AT that checkpoint (keep changes up to and including it)
---R on final checkpoint: Do nothing (already at final state)
---@param self FSMonitor.Monitor
---@param checkpoint_idx number Index of checkpoint to revert to
---@param checkpoints FSMonitor.Checkpoint[] Array of checkpoints
---@return table|nil result {new_changes, new_checkpoints, reverted_count, error_count}
function FSMonitor:revert_to_checkpoint(checkpoint_idx, checkpoints)
  if not checkpoints or #checkpoints == 0 then return nil end

  if checkpoint_idx < 1 or checkpoint_idx > #checkpoints then return nil end

  if checkpoint_idx == #checkpoints then return nil end

  local cwd = vim.fn.getcwd()
  local target_checkpoint = checkpoints[checkpoint_idx]

  -- Revert to state AT checkpoint - keep changes up to and including this checkpoint
  local changes_to_revert = {}
  local changes_to_keep = {}

  for _, change in ipairs(self.changes) do
    if change.timestamp <= target_checkpoint.timestamp then
      table.insert(changes_to_keep, change)
    else
      table.insert(changes_to_revert, change)
    end
  end

  if #changes_to_revert == 0 then return nil end

  -- Group by file - track the FIRST change AFTER target checkpoint for each file
  -- That change's old_content represents the state at the target checkpoint
  local file_actions = {}
  for _, change in ipairs(changes_to_revert) do
    if not file_actions[change.path] then
      file_actions[change.path] = {
        first_change = change, -- First change after target checkpoint
      }
    end
  end

  local reverted, errors, modified_files = self:_apply_file_reverts(file_actions, cwd)

  self:_refresh_modified_buffers(modified_files, cwd)

  self.changes = changes_to_keep
  self:_cleanup_content_cache(changes_to_keep)

  local new_checkpoints = {}
  for i = 1, checkpoint_idx do
    table.insert(new_checkpoints, checkpoints[i])
  end

  return {
    new_changes = changes_to_keep,
    new_checkpoints = new_checkpoints,
    reverted_count = reverted,
    error_count = errors,
    is_full_revert = false,
  }
end

---Revert ALL changes to original state (before any monitoring)
---@param self FSMonitor.Monitor
---@param _checkpoints table List of all checkpoints (will be cleared)
---@return table|nil result { new_changes, new_checkpoints, reverted_count, error_count } or nil if no changes
function FSMonitor:revert_to_original(_checkpoints)
  if #self.changes == 0 then return nil end

  local cwd = vim.fn.getcwd()

  -- Group by file - track the FIRST change for each file
  -- That change's old_content represents the original state
  local file_actions = {}
  for _, change in ipairs(self.changes) do
    if not file_actions[change.path] then file_actions[change.path] = {
      first_change = change,
    } end
  end

  local reverted, errors, modified_files = self:_apply_file_reverts(file_actions, cwd)

  self:_refresh_modified_buffers(modified_files, cwd)

  self.changes = {}
  self.content_cache = {}

  return {
    new_changes = {},
    new_checkpoints = {},
    reverted_count = reverted,
    error_count = errors,
    is_full_revert = true,
  }
end

---Apply file reverts based on file_actions map
---@param file_actions table Map of filepath -> { first_change }
---@param cwd string Current working directory
---@return number reverted Count of successfully reverted files
---@return number errors Count of errors
---@return string[] modified_files List of modified file paths
function FSMonitor:_apply_file_reverts(file_actions, cwd)
  local reverted = 0
  local errors = 0
  local modified_files = {}

  for filepath, actions in pairs(file_actions) do
    local first_change = actions.first_change
    local absolute_path = vim.fs.joinpath(cwd, filepath)

    if first_change.kind == "created" then
      -- File was created after target state - delete it
      local ok, _ = safe_delete_file(absolute_path)
      if ok then
        reverted = reverted + 1
        table.insert(modified_files, filepath)
      else
        errors = errors + 1
      end
    elseif first_change.kind == "modified" or first_change.kind == "deleted" then
      -- File was modified or deleted - restore to old_content
      local old_content = first_change.old_content
      if old_content then
        local ok, _ = safe_write_file(absolute_path, old_content)
        if ok then
          reverted = reverted + 1
          table.insert(modified_files, filepath)
        else
          errors = errors + 1
        end
      else
        errors = errors + 1
      end
    end
  end

  return reverted, errors, modified_files
end

---Trigger checktime for any open buffers that were modified
---@param modified_files string[] List of relative file paths
---@param cwd string Current working directory
function FSMonitor:_refresh_modified_buffers(modified_files, cwd)
  vim.schedule(function()
    for _, filepath in ipairs(modified_files) do
      local absolute_path = vim.fs.joinpath(cwd, filepath)
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
          local buf_name = vim.api.nvim_buf_get_name(bufnr)
          if buf_name == absolute_path then vim.cmd("checktime " .. bufnr) end
        end
      end
    end
  end)
end

---Clean up content cache for files no longer in changes
---@param changes_to_keep FSMonitor.Change[]
function FSMonitor:_cleanup_content_cache(changes_to_keep)
  local files_with_changes = {}
  for _, change in ipairs(changes_to_keep) do
    files_with_changes[change.path] = true
  end
  for path, _ in pairs(self.content_cache) do
    if not files_with_changes[path] then self.content_cache[path] = nil end
  end
end

return FSMonitor
