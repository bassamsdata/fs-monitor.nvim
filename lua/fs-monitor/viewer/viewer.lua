---@module "fs-monitor.types"

---@class FSMonitor.Viewer
local Viewer = {}

local api = vim.api
local set_option = vim.api.nvim_set_option_value
local fmt = string.format

Viewer.__index = Viewer

---Create a new Viewer instance
---@param changes FSMonitor.Change[]
---@param checkpoints? FSMonitor.Checkpoint[]
---@param opts? { fs_monitor?: FSMonitor.Monitor, on_revert?: fun(changes: FSMonitor.Change[], checkpoints: FSMonitor.Checkpoint[]) }
---@return FSMonitor.Viewer
function Viewer.new(changes, checkpoints, opts)
  checkpoints = checkpoints or {}
  opts = opts or {}

  local state_module = require("fs-monitor.viewer.state")

  local summary = state_module.generate_summary(changes)
  local current_win = api.nvim_get_current_win()

  local self = setmetatable({
    original_win = current_win,
    files_buf = nil,
    checkpoints_buf = nil,
    right_buf = nil,
    files_win = nil,
    checkpoints_win = nil,
    right_win = nil,
    help_buf = nil,
    help_win = nil,
    ns = api.nvim_create_namespace("fs_monitor_viewer"),
    aug = nil,
    summary = summary,
    checkpoints = checkpoints,
    all_changes = changes,
    filtered_changes = changes,
    selected_file_idx = 1,
    selected_checkpoint_idx = nil,
    is_preview_only = false,
    is_fullscreen = false,
    fs_monitor = opts.fs_monitor,
    on_revert = opts.on_revert,
    hunks = {},
    hunk_ranges = {},
    line_mappings = {},
    current_filepath = nil,
    word_diff = require("fs-monitor.config").ui_options.word_diff,
    right_keymaps = {},
    preview_cache = {},
    cache_enabled = require("fs-monitor.config").ui_options.cache_preview,
    cache_max_files = require("fs-monitor.config").ui_options.cache_max_files or 100,
    cache_access_order = {},
  }, Viewer)

  return self
end

---Get viewer configuration
---@return FSMonitor.DiffConfig
function Viewer:get_config()
  return require("fs-monitor.config").ui_options
end

---Get geometry based on fullscreen state
---@private
---@return table geometry
function Viewer:_get_geometry()
  local geometry = require("fs-monitor.viewer.geometry")
  return geometry.get(self.is_fullscreen)
end

---Generate summary from changes
---@private
---@param changes FSMonitor.Change[]
---@return table summary
function Viewer:_generate_summary(changes)
  local state_module = require("fs-monitor.viewer.state")
  return state_module.generate_summary(changes)
end

---Update preview for selected file
function Viewer:_update_preview()
  local updater = require("fs-monitor.viewer.updater")
  updater.update_preview(self)
end

---Refresh all UI panels
---@param opts? table
function Viewer:_refresh_ui(opts)
  local updater = require("fs-monitor.viewer.updater")
  updater.refresh_ui(self, opts)
end

---Update window configuration safely
---@param win number
---@param config table
function Viewer:_update_win_config(win, config)
  if api.nvim_win_is_valid(win) then pcall(api.nvim_win_set_config, win, config) end
end

---Find which hunk the current line belongs to
---@package
---@param current_line number Current cursor line (1-indexed)
---@return number|nil hunk_index
function Viewer:_find_current_hunk(current_line)
  for i, range in ipairs(self.hunk_ranges) do
    if current_line >= range.start_line and current_line <= range.end_line then return i end
  end
  return nil
end

---Get cached preview for a file
---@package
---@param filepath string
---@return table|nil cached_preview
function Viewer:_get_cached_preview(filepath)
  if not self.cache_enabled then return nil end
  return self.preview_cache[filepath]
end

---Set cached preview for a file
---@package
---@param filepath string
---@param cache_data table
function Viewer:_set_cached_preview(filepath, cache_data)
  if not self.cache_enabled then return end

  if self.preview_cache[filepath] then
    for i, path in ipairs(self.cache_access_order) do
      if path == filepath then
        table.remove(self.cache_access_order, i)
        break
      end
    end
  end

  while #self.cache_access_order >= self.cache_max_files do
    local oldest_path = table.remove(self.cache_access_order, 1)
    self.preview_cache[oldest_path] = nil
  end

  self.preview_cache[filepath] = cache_data
  table.insert(self.cache_access_order, filepath)
end

---Clear entire preview cache
---@package
function Viewer:_clear_preview_cache()
  self.preview_cache = {}
  self.cache_access_order = {}
end

---Remove specific file from cache
---@package
---@param filepath string
function Viewer:_invalidate_cache_for_file(filepath)
  if self.preview_cache[filepath] then
    self.preview_cache[filepath] = nil
    for i, path in ipairs(self.cache_access_order) do
      if path == filepath then
        table.remove(self.cache_access_order, i)
        break
      end
    end
  end
end

---Get first content line of a hunk (skip the @@ header line)
---@package
---@param range table
---@return number
function Viewer:_get_hunk_content_line(range)
  return range.start_line + 4
end

---Navigate to next/previous file
---@param direction number 1 for next, -1 for previous
---@return FSMonitor.Viewer self
function Viewer:navigate_files(direction)
  local render = require("fs-monitor.viewer.render")

  if #self.summary.files == 0 then return self end

  self.selected_file_idx = self.selected_file_idx or 1

  local new_file_idx = self.selected_file_idx + direction
  new_file_idx = math.max(1, math.min(new_file_idx, #self.summary.files))

  self.selected_file_idx = new_file_idx

  if api.nvim_win_is_valid(self.files_win) then
    pcall(api.nvim_win_set_cursor, self.files_win, { self.selected_file_idx, 0 })
  end

  self:_update_preview()
  set_option("modifiable", true, { buf = self.files_buf })
  render.new(self.files_buf, self.ns):render_file_list(self.summary.files, self.summary.by_file, new_file_idx)
  set_option("modifiable", false, { buf = self.files_buf })

  return self
end

---Navigate to next file
---@return FSMonitor.Viewer self
function Viewer:next_file()
  return self:navigate_files(1)
end

---Navigate to previous file
---@return FSMonitor.Viewer self
function Viewer:prev_file()
  return self:navigate_files(-1)
end

---Jump to next hunk in diff preview
---@return FSMonitor.Viewer self
function Viewer:next_hunk()
  if not api.nvim_win_is_valid(self.right_win) then return self end
  if not self.hunk_ranges or #self.hunk_ranges == 0 then return self end

  local cursor = api.nvim_win_get_cursor(self.right_win)
  local current_line = cursor[1]

  for _, range in ipairs(self.hunk_ranges) do
    if range.start_line > current_line then
      api.nvim_win_set_cursor(self.right_win, { self:_get_hunk_content_line(range), 0 })
      vim.cmd("normal! zz")
      return self
    end
  end

  api.nvim_win_set_cursor(self.right_win, { self:_get_hunk_content_line(self.hunk_ranges[1]), 0 })
  vim.cmd("normal! zz")

  return self
end

---Jump to previous hunk in diff preview
---@return FSMonitor.Viewer self
function Viewer:prev_hunk()
  if not api.nvim_win_is_valid(self.right_win) then return self end
  if not self.hunk_ranges or #self.hunk_ranges == 0 then return self end

  local cursor = api.nvim_win_get_cursor(self.right_win)
  local current_line = cursor[1]

  local current_hunk_idx = self:_find_current_hunk(current_line)

  if current_hunk_idx then
    if current_hunk_idx > 1 then
      api.nvim_win_set_cursor(
        self.right_win,
        { self:_get_hunk_content_line(self.hunk_ranges[current_hunk_idx - 1]), 0 }
      )
      vim.cmd("normal! zz")
      return self
    end
  else
    for i = #self.hunk_ranges, 1, -1 do
      if self.hunk_ranges[i].start_line < current_line then
        api.nvim_win_set_cursor(self.right_win, { self:_get_hunk_content_line(self.hunk_ranges[i]), 0 })
        vim.cmd("normal! zz")
        return self
      end
    end
  end

  api.nvim_win_set_cursor(self.right_win, { self:_get_hunk_content_line(self.hunk_ranges[#self.hunk_ranges]), 0 })
  vim.cmd("normal! zz")

  return self
end

---Open file in editor with optional line number
---@package
---@param filepath string Absolute path to file
---@param line? number Optional line number to jump to
function Viewer:_open_file_at_line(filepath, line)
  local bufnr = vim.fn.bufnr(filepath)
  if bufnr == -1 then
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    bufnr = api.nvim_get_current_buf()
  else
    vim.cmd("buffer " .. bufnr)
  end

  if line then
    local buf_lines = api.nvim_buf_line_count(bufnr)
    if line > buf_lines then line = buf_lines end
    pcall(api.nvim_win_set_cursor, 0, { line, 0 })
    vim.cmd("normal! zz")
  end
end

---Go to the selected file in the editor (from files window)
---@return FSMonitor.Viewer self
function Viewer:goto_file_in_editor()
  local filepath = self.summary.files[self.selected_file_idx]
  if not filepath then return self end

  local cwd = vim.fn.getcwd()
  local absolute_path = vim.fs.joinpath(cwd, filepath)

  self:close(false)
  self:_open_file_at_line(absolute_path)

  return self
end

---Jump from diff preview line to actual file line
---@return FSMonitor.Viewer self
function Viewer:jump_to_file_line()
  if not self.current_filepath or not self.line_mappings then return self end

  local util = require("fs-monitor.utils.util")
  local cursor = api.nvim_win_get_cursor(self.right_win)
  local diff_line = cursor[1] - 1

  local mapping = self.line_mappings[diff_line]
  if not mapping then
    util.notify("Please ensure the cursor is over a valid hunk", vim.log.levels.WARN)
    return self
  end

  local target_line = mapping.updated_line or mapping.original_line
  if not target_line then
    util.notify("This line was removed and no longer exists in the file", vim.log.levels.WARN)
    return self
  end

  local cwd = vim.fn.getcwd()
  local absolute_path = vim.fs.joinpath(cwd, self.current_filepath)
  local stat = vim.uv.fs_stat(absolute_path)
  if not stat then
    util.notify(fmt("File not found: %s", self.current_filepath), vim.log.levels.WARN)
    return self
  end

  self:close(false)
  self:_open_file_at_line(absolute_path, target_line)

  return self
end

---Filter changes based on checkpoint and mode
---@param checkpoint_idx number
---@param mode? "cumulative"|"differential"
---@return FSMonitor.Viewer self
function Viewer:apply_checkpoint_filter(checkpoint_idx, mode)
  if checkpoint_idx < 1 or checkpoint_idx > #self.checkpoints then return self end

  mode = mode or "cumulative"
  local checkpoint = self.checkpoints[checkpoint_idx]
  self.selected_checkpoint_idx = checkpoint_idx

  local min_timestamp = 0
  if mode == "differential" and checkpoint_idx > 1 then
    min_timestamp = self.checkpoints[checkpoint_idx - 1].timestamp
  end

  local filtered = {}
  for _, change in ipairs(self.all_changes) do
    if change.timestamp > min_timestamp and change.timestamp <= checkpoint.timestamp then
      table.insert(filtered, change)
    end
  end

  self.filtered_changes = filtered
  self.summary = self:_generate_summary(filtered)
  self.selected_file_idx = 1

  self:_clear_preview_cache()

  self:_refresh_ui({ selected_checkpoint_idx = checkpoint_idx, show_empty_message = true })

  return self
end

---Reset to show all changes
---@return FSMonitor.Viewer self
function Viewer:reset_checkpoint_filter()
  self.selected_checkpoint_idx = nil
  self.filtered_changes = self.all_changes
  self.summary = self:_generate_summary(self.all_changes)
  self.selected_file_idx = 1

  self:_clear_preview_cache()

  self:_refresh_ui()

  return self
end

---Generate help lines dynamically from keymaps config
---@package
---@return string[]
function Viewer:_generate_help_lines()
  local cfg = self:get_config()
  local km = cfg.keymaps

  return {
    "## General",
    fmt("- **%s**: %s", km.toggle_help.key, km.toggle_help.desc),
    fmt("- **%s** / **%s**: %s", km.close.key, km.close_alt.key, km.close.desc),
    fmt("- **%s**: %s", km.cycle_focus.key, km.cycle_focus.desc),
    fmt("- **%s**: %s", km.toggle_preview.key, km.toggle_preview.desc),
    fmt("- **%s**: %s", km.toggle_fullscreen.key, km.toggle_fullscreen.desc),
    fmt("- **%s**: %s", km.toggle_word_diff.key, km.toggle_word_diff.desc),
    "",
    "## Navigation",
    fmt("- **%s** / **%s**: Next/Prev file", km.next_file_alt.key, km.prev_file_alt.key),
    fmt("- **%s** / **%s**: Next/Prev hunk", km.next_hunk.key, km.prev_hunk.key),
    fmt("- **%s** / **%s**: Next/Prev file (preview)", km.next_file.key, km.prev_file.key),
    fmt("- **%s**: %s (files window)", km.goto_file.key, km.goto_file.desc),
    fmt("- **%s** / **%s**: %s (preview)", km.goto_hunk.key, km.goto_hunk_alt.key, km.goto_hunk.desc),
    "",
    "## Actions",
    fmt("- **%s**: %s", km.revert_hunk.key, km.revert_hunk.desc),
    fmt("- **%s**: %s", km.worktree_pane.key, km.worktree_pane.desc),
    "",
    "## Checkpoints",
    fmt("- **%s**: %s (safe - shows cycle changes)", km.view_checkpoint.key, km.view_checkpoint.desc),
    fmt("- **%s**: %s (safe - shows accumulated to cycle)", km.view_cumulative.key, km.view_cumulative.desc),
    fmt("- **%s**: Reset checkpoint filter (safe - resets UI only)", km.reset_filter.key),
    fmt("- **%s**: %s", km.revert_checkpoint.key, km.revert_checkpoint.desc),
    fmt("- **%s**: %s", km.revert_all.key, km.revert_all.desc),
  }
end

---Toggle help window
---@return FSMonitor.Viewer self
function Viewer:toggle_help()
  local cfg = self:get_config()
  if self.help_win and api.nvim_win_is_valid(self.help_win) then
    pcall(api.nvim_win_close, self.help_win, true)
    if self.help_buf and api.nvim_buf_is_valid(self.help_buf) then
      pcall(api.nvim_buf_delete, self.help_buf, { force = true })
    end
    self.help_win = nil
    self.help_buf = nil
    return self
  end

  local geom = self:_get_geometry()

  self.help_buf = api.nvim_create_buf(false, true)
  set_option("buftype", "nofile", { buf = self.help_buf })
  set_option("bufhidden", "wipe", { buf = self.help_buf })
  set_option("filetype", "markdown", { buf = self.help_buf })

  local lines = self:_generate_help_lines()
  api.nvim_buf_set_lines(self.help_buf, 0, -1, false, lines)

  self.help_win = api.nvim_open_win(self.help_buf, true, {
    relative = "editor",
    row = geom.row,
    col = geom.left_col,
    width = geom.left_w,
    height = geom.height,
    style = "minimal",
    border = "rounded",
    zindex = cfg.help_zindex,
    title = " 󰋖 Help ",
    title_pos = "center",
  })

  vim.wo[self.help_win].wrap = true
  vim.wo[self.help_win].conceallevel = 2

  local close_keys = { cfg.keymaps.close.key, cfg.keymaps.close_alt.key, cfg.keymaps.toggle_help.key }
  for _, key in ipairs(close_keys) do
    vim.keymap.set("n", key, function()
      self:toggle_help()
    end, {
      buffer = self.help_buf,
      noremap = true,
      silent = true,
      nowait = true,
    })
  end

  return self
end

---Toggle preview-only mode
---@return FSMonitor.Viewer self
function Viewer:toggle_preview_only()
  local g = self:_get_geometry()

  if self.is_preview_only then
    self:_update_win_config(self.files_win, {
      relative = "editor",
      row = g.row,
      col = g.left_col,
      width = g.left_w,
      height = g.files_h,
      hide = false,
    })
    self:_update_win_config(self.checkpoints_win, {
      relative = "editor",
      row = g.checkpoints_row,
      col = g.left_col,
      width = g.left_w,
      height = g.checkpoints_h,
      hide = false,
    })
    self:_update_win_config(self.right_win, {
      relative = "editor",
      row = g.row,
      col = g.right_col,
      width = g.right_w,
      height = g.height,
    })
    self.is_preview_only = false
  else
    local total_width = g.left_w + g.gap + g.right_w
    if self.is_fullscreen then total_width = vim.o.columns - 2 end

    self:_update_win_config(self.files_win, { hide = true })
    self:_update_win_config(self.checkpoints_win, { hide = true })
    self:_update_win_config(self.right_win, {
      relative = "editor",
      row = g.row,
      col = self.is_fullscreen and 0 or g.left_col,
      width = total_width,
      height = g.height,
    })
    if api.nvim_win_is_valid(self.right_win) then api.nvim_set_current_win(self.right_win) end
    self.is_preview_only = true
  end

  return self
end

---Toggle fullscreen mode
---@return FSMonitor.Viewer self
function Viewer:toggle_fullscreen()
  self.is_fullscreen = not self.is_fullscreen
  local g = self:_get_geometry()

  if self.is_preview_only then
    local total_width = g.left_w + g.gap + g.right_w
    if self.is_fullscreen then total_width = vim.o.columns - 2 end
    self:_update_win_config(self.right_win, {
      relative = "editor",
      row = g.row,
      col = self.is_fullscreen and 0 or g.left_col,
      width = total_width,
      height = g.height,
    })
  else
    self:_update_win_config(self.files_win, {
      relative = "editor",
      row = g.row,
      col = g.left_col,
      width = g.left_w,
      height = g.files_h,
    })
    self:_update_win_config(self.checkpoints_win, {
      relative = "editor",
      row = g.checkpoints_row,
      col = g.left_col,
      width = g.left_w,
      height = g.checkpoints_h,
    })
    self:_update_win_config(self.right_win, {
      relative = "editor",
      row = g.row,
      col = g.right_col,
      width = g.right_w,
      height = g.height,
    })
  end

  return self
end

---Toggle word-level diff highlighting
---@return FSMonitor.Viewer self
function Viewer:toggle_word_diff()
  local util = require("fs-monitor.utils.util")

  self.word_diff = not self.word_diff

  self:_clear_preview_cache()

  if self.selected_file_idx and #self.summary.files > 0 then self:_update_preview() end

  local status = self.word_diff and "enabled" or "disabled"
  util.notify(fmt("Word diff %s", status), vim.log.levels.INFO)

  return self
end

---Revert the hunk under the cursor
---@return FSMonitor.Viewer self
function Viewer:revert_current_hunk()
  local operations = require("fs-monitor.viewer.operations")
  return operations.revert_hunk(self)
end

---Revert to state at a checkpoint using FSMonitor
---@param checkpoint_idx number
---@return FSMonitor.Viewer self
function Viewer:revert_to_checkpoint(checkpoint_idx)
  local operations = require("fs-monitor.viewer.operations")
  return operations.revert_to_checkpoint(self, checkpoint_idx)
end

---Revert ALL changes to original state
---@return FSMonitor.Viewer self
function Viewer:revert_to_original()
  local operations = require("fs-monitor.viewer.operations")
  return operations.revert_to_original(self)
end

---Close all windows and cleanup resources
---@param restore_focus? boolean Whether to restore focus to original window (default true)
---@return FSMonitor.Viewer self
function Viewer:close(restore_focus)
  if restore_focus == nil then restore_focus = true end

  if self.aug then
    pcall(api.nvim_del_augroup_by_id, self.aug)
    self.aug = nil
  end

  local windows = { self.files_win, self.checkpoints_win, self.right_win, self.help_win }
  for _, win in ipairs(windows) do
    if win and api.nvim_win_is_valid(win) then pcall(api.nvim_win_close, win, true) end
  end

  local buffers = { self.files_buf, self.checkpoints_buf, self.right_buf, self.help_buf }
  for _, buf in ipairs(buffers) do
    if buf and api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end
  end

  local ui_utils = require("fs-monitor.utils.ui")
  ui_utils.close_background_window()

  if restore_focus and self.original_win and api.nvim_win_is_valid(self.original_win) then
    pcall(api.nvim_set_current_win, self.original_win)
  end

  return self
end

---Show the viewer (public entry point)
---@return FSMonitor.Viewer self
function Viewer:show()
  local highlights = require("fs-monitor.utils.highlights")
  local ui_utils = require("fs-monitor.utils.ui")
  local render = require("fs-monitor.viewer.render")
  local builder = require("fs-monitor.viewer.builder")

  highlights.setup()
  ui_utils.create_background_window()

  local cfg = self:get_config()
  local geom = self:_get_geometry()

  builder.create_buffers(self)
  builder.create_windows(self, geom, cfg)

  render.new(self.files_buf, self.ns):render_file_list(self.summary.files, self.summary.by_file, self.selected_file_idx)
  render
    .new(self.checkpoints_buf, self.ns)
    :render_checkpoints(self.checkpoints, self.all_changes, self.selected_checkpoint_idx)

  builder.setup_keymaps(self, cfg)
  builder.setup_autocmds(self)

  if #self.summary.files > 0 then
    pcall(api.nvim_win_set_cursor, self.files_win, { 1, 0 })
    self:_update_preview()
  end

  return self
end

return Viewer
