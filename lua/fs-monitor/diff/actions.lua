---@class FSMonitor.Diff.Actions
local M = {}

local api = vim.api
local set_option = vim.api.nvim_set_option_value

---Get diff configuration
---@return FSMonitor.DiffConfig
local function get_config()
  return require("fs-monitor.config").diff_options
end

-- ============================================================================
-- WINDOW MANAGEMENT
-- ============================================================================

---Update window configuration safely
---@param win number
---@param config table
local function update_win_config(win, config)
  if api.nvim_win_is_valid(win) then pcall(api.nvim_win_set_config, win, config) end
end

---Close all windows
---@param state table
---@param restore_focus? boolean Whether to restore focus to original window (default true)
function M.close_windows(state, restore_focus)
  if restore_focus == nil then restore_focus = true end

  if state.aug then
    pcall(api.nvim_del_augroup_by_id, state.aug)
    state.aug = nil
  end

  local windows = { state.files_win, state.checkpoints_win, state.right_win, state.help_win }
  for _, win in ipairs(windows) do
    if win and api.nvim_win_is_valid(win) then pcall(api.nvim_win_close, win, true) end
  end

  local buffers = { state.files_buf, state.checkpoints_buf, state.right_buf, state.help_buf }
  for _, buf in ipairs(buffers) do
    if buf and api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end
  end

  local ui = require("fs-monitor.utils.ui")
  ui.close_background_window()

  if restore_focus and state.original_win and api.nvim_win_is_valid(state.original_win) then
    pcall(api.nvim_set_current_win, state.original_win)
  end
end

-- ============================================================================
-- NAVIGATION
-- ============================================================================

---Reapply keymaps to right buffer (needed after filetype changes)
---@param state table
local function reapply_right_keymaps(state)
  if not state.right_keymaps or not api.nvim_buf_is_valid(state.right_buf) then return end

  for _, keymap in ipairs(state.right_keymaps) do
    vim.keymap.set("n", keymap.key, keymap.callback, {
      buffer = state.right_buf,
      noremap = true,
      silent = true,
      nowait = true,
      desc = keymap.desc,
    })
  end
end

---Update preview for selected file
---@param state table
---@param idx number
function M.update_preview(state, idx)
  local render = require("fs-monitor.diff.render")
  local hunks_util = require("fs-monitor.diff.hunks")
  local util = require("fs-monitor.utils.util")
  local cfg = get_config()

  local filepath = state.summary.files[idx]
  if not filepath then return end

  local file_info = state.summary.by_file[filepath]
  if not file_info or #file_info.changes == 0 then return end

  local first_change = file_info.changes[1]
  local last_change = file_info.changes[#file_info.changes]
  local net_operation = file_info.net_operation

  local old_lines = {}
  local new_lines = {}

  if net_operation == "created" then
    old_lines = {}
    if last_change.new_content then
      new_lines = vim.split(last_change.new_content, "\n", { plain = true })
    else
      new_lines = { "(empty file)" }
    end
  elseif net_operation == "deleted" then
    if first_change.old_content then
      old_lines = vim.split(first_change.old_content, "\n", { plain = true })
    else
      old_lines = { "(empty file)" }
    end
    new_lines = {}
  else
    if first_change.old_content then old_lines = vim.split(first_change.old_content, "\n", { plain = true }) end
    if last_change.new_content then new_lines = vim.split(last_change.new_content, "\n", { plain = true }) end
  end

  local hunks = hunks_util.calculate_hunks(old_lines, new_lines, 3)
  local ft = vim.filetype.match({ filename = filepath }) or ""

  set_option("modifiable", true, { buf = state.right_buf })
  api.nvim_buf_clear_namespace(state.right_buf, state.ns, 0, -1)
  local _, line_mappings, hunk_ranges = render.render_diff(state.right_buf, state.ns, hunks)
  set_option("modifiable", false, { buf = state.right_buf })

  state.line_mappings = line_mappings
  state.current_filepath = filepath
  state.hunks = hunks
  state.hunk_ranges = hunk_ranges

  if ft and ft ~= "" then
    set_option("filetype", ft, { buf = state.right_buf })
    reapply_right_keymaps(state)
  end

  if api.nvim_win_is_valid(state.right_win) then
    local title_icon = cfg.icons.title_modified
    if net_operation == "created" then
      title_icon = cfg.icons.title_created
    elseif net_operation == "deleted" then
      title_icon = cfg.icons.title_deleted
    elseif net_operation == "renamed" then
      title_icon = cfg.icons.title_renamed
    end
    local title_name = vim.fn.fnamemodify(filepath, ":t")
    if net_operation == "renamed" and file_info.old_path then
      local old_name = vim.fn.fnamemodify(file_info.old_path, ":t")
      title_name = old_name .. " → " .. title_name
    end

    local hunk_count_str = ""
    if #hunks > 0 then hunk_count_str = string.format(" [%d %s]", #hunks, util.pluralize(#hunks, "hunk")) end

    api.nvim_win_set_config(state.right_win, {
      title = string.format(" %s %s%s ", title_icon, title_name, hunk_count_str),
      title_pos = "center",
    })
  end
end

---Navigate to next/previous file
---@param state table
---@param direction number
function M.navigate_files(state, direction)
  local render = require("fs-monitor.diff.render")

  if #state.summary.files == 0 then return end

  state.selected_file_idx = state.selected_file_idx or 1

  local new_file_idx = state.selected_file_idx + direction
  new_file_idx = math.max(1, math.min(new_file_idx, #state.summary.files))

  state.selected_file_idx = new_file_idx

  if api.nvim_win_is_valid(state.files_win) then
    pcall(api.nvim_win_set_cursor, state.files_win, { state.selected_file_idx, 0 })
  end

  M.update_preview(state, new_file_idx)
  render.render_file_list(
    state.files_buf,
    state.ns,
    state.summary.files,
    state.summary.by_file,
    state.selected_file_idx
  )
end

---Find which hunk the current line belongs to
---@param hunk_ranges table[] Array of {start_line, end_line}
---@param current_line number Current cursor line (1-indexed)
---@return number|nil hunk_index
local function find_current_hunk(hunk_ranges, current_line)
  for i, range in ipairs(hunk_ranges) do
    if current_line >= range.start_line and current_line <= range.end_line then return i end
  end
  return nil
end

---Jump to next hunk in diff preview
---@param state table
function M.jump_next_hunk(state)
  if not api.nvim_win_is_valid(state.right_win) then return end
  if not state.hunk_ranges or #state.hunk_ranges == 0 then return end

  local cursor = api.nvim_win_get_cursor(state.right_win)
  local current_line = cursor[1]

  for _, range in ipairs(state.hunk_ranges) do
    if range.start_line > current_line then
      api.nvim_win_set_cursor(state.right_win, { range.start_line, 0 })
      vim.cmd("normal! zz")
      return
    end
  end

  api.nvim_win_set_cursor(state.right_win, { state.hunk_ranges[1].start_line, 0 })
  vim.cmd("normal! zz")
end

---Jump to previous hunk in diff preview
---@param state table
function M.jump_prev_hunk(state)
  if not api.nvim_win_is_valid(state.right_win) then return end
  if not state.hunk_ranges or #state.hunk_ranges == 0 then return end

  local cursor = api.nvim_win_get_cursor(state.right_win)
  local current_line = cursor[1]

  local current_hunk_idx = find_current_hunk(state.hunk_ranges, current_line)

  if current_hunk_idx then
    local current_hunk = state.hunk_ranges[current_hunk_idx]
    if current_line > current_hunk.start_line then
      api.nvim_win_set_cursor(state.right_win, { current_hunk.start_line, 0 })
      vim.cmd("normal! zz")
      return
    end

    if current_hunk_idx > 1 then
      api.nvim_win_set_cursor(state.right_win, { state.hunk_ranges[current_hunk_idx - 1].start_line, 0 })
      vim.cmd("normal! zz")
      return
    end
  else
    for i = #state.hunk_ranges, 1, -1 do
      if state.hunk_ranges[i].start_line < current_line then
        api.nvim_win_set_cursor(state.right_win, { state.hunk_ranges[i].start_line, 0 })
        vim.cmd("normal! zz")
        return
      end
    end
  end

  api.nvim_win_set_cursor(state.right_win, { state.hunk_ranges[#state.hunk_ranges].start_line, 0 })
  vim.cmd("normal! zz")
end

---Jump from diff preview line to actual file line
---@param state table
function M.jump_to_file_line(state)
  if not state.current_filepath or not state.line_mappings then return end

  local util = require("fs-monitor.utils.util")
  local cursor = api.nvim_win_get_cursor(state.right_win)
  local diff_line = cursor[1] - 1

  local mapping = state.line_mappings[diff_line]
  if not mapping then
    util.notify("Please ensure the cursor is over a valid hunk", vim.log.levels.WARN)
    return
  end

  local target_line = mapping.updated_line or mapping.original_line
  if not target_line then
    util.notify("This line was removed and no longer exists in the file", vim.log.levels.WARN)
    return
  end

  local cwd = vim.fn.getcwd()
  local absolute_path = vim.fs.joinpath(cwd, state.current_filepath)
  local stat = vim.uv.fs_stat(absolute_path)
  if not stat then
    util.notify(string.format("File not found: %s", state.current_filepath), vim.log.levels.WARN)
    return
  end

  M.close_windows(state, false)

  local bufnr = vim.fn.bufnr(absolute_path)
  if bufnr == -1 then
    vim.cmd("edit " .. vim.fn.fnameescape(absolute_path))
    bufnr = vim.api.nvim_get_current_buf()
  else
    vim.cmd("buffer " .. bufnr)
  end
  local buf_lines = api.nvim_buf_line_count(bufnr)

  if target_line > buf_lines then target_line = buf_lines end

  pcall(api.nvim_win_set_cursor, 0, { target_line, 0 })
  vim.cmd("normal! zz")
end

-- ============================================================================
-- CHECKPOINT FILTERING
-- ============================================================================

---Filter changes based on checkpoint and mode
---@param state table
---@param checkpoint_idx number
---@param mode? "cumulative"|"differential"
function M.apply_checkpoint_filter(state, checkpoint_idx, mode)
  local render = require("fs-monitor.diff.render")

  if checkpoint_idx < 1 or checkpoint_idx > #state.checkpoints then return end

  mode = mode or "cumulative"
  local checkpoint = state.checkpoints[checkpoint_idx]
  state.selected_checkpoint_idx = checkpoint_idx

  local min_timestamp = 0
  if mode == "differential" and checkpoint_idx > 1 then
    min_timestamp = state.checkpoints[checkpoint_idx - 1].timestamp
  end

  local filtered = {}
  for _, change in ipairs(state.all_changes) do
    if change.timestamp > min_timestamp and change.timestamp <= checkpoint.timestamp then
      table.insert(filtered, change)
    end
  end

  state.filtered_changes = filtered

  local summary = state.generate_summary(filtered)
  state.summary = summary

  state.selected_file_idx = 1
  render.render_file_list(state.files_buf, state.ns, summary.files, summary.by_file, state.selected_file_idx)
  render.render_checkpoints(state.checkpoints_buf, state.ns, state.checkpoints, state.all_changes, checkpoint_idx)

  if #summary.files > 0 then
    pcall(api.nvim_win_set_cursor, state.files_win, { 1, 0 })
    M.update_preview(state, 1)
  else
    set_option("modifiable", true, { buf = state.right_buf })
    api.nvim_buf_set_lines(state.right_buf, 0, -1, false, { "", "No changes at this checkpoint", "" })
    set_option("modifiable", false, { buf = state.right_buf })
  end
end

---Reset to show all changes
---@param state table
function M.reset_checkpoint_filter(state)
  local render = require("fs-monitor.diff.render")

  state.selected_checkpoint_idx = nil
  state.filtered_changes = state.all_changes

  local summary = state.generate_summary(state.all_changes)
  state.summary = summary

  state.selected_file_idx = 1
  render.render_file_list(state.files_buf, state.ns, summary.files, summary.by_file, state.selected_file_idx)
  render.render_checkpoints(state.checkpoints_buf, state.ns, state.checkpoints, state.all_changes, nil)

  if #summary.files > 0 then
    pcall(api.nvim_win_set_cursor, state.files_win, { 1, 0 })
    M.update_preview(state, 1)
  end
end

-- ============================================================================
-- REVERT OPERATIONS
-- ============================================================================

---Revert to state at a checkpoint using FSMonitor
---@param state table
---@param checkpoint_idx number
function M.revert_to_checkpoint(state, checkpoint_idx)
  local render = require("fs-monitor.diff.render")
  local ui = require("fs-monitor.utils.ui")
  local util = require("fs-monitor.utils.util")

  if checkpoint_idx < 1 or checkpoint_idx > #state.checkpoints then return end

  if checkpoint_idx == #state.checkpoints then
    util.notify("Already at final checkpoint - nothing to revert")
    return
  end

  if not state.fs_monitor then
    util.notify("Cannot revert: no file system monitor available", vim.log.levels.ERROR)
    return
  end

  local checkpoint = state.checkpoints[checkpoint_idx]
  local target_label = checkpoint.label or string.format("Checkpoint %d", checkpoint_idx)

  local files_to_revert = {}
  for _, change in ipairs(state.all_changes) do
    if change.timestamp > checkpoint.timestamp then files_to_revert[change.path] = true end
  end
  local file_count = vim.tbl_count(files_to_revert)

  if file_count == 0 then
    util.notify("No changes to revert")
    return
  end

  local confirm_result = ui.confirm(
    string.format("Revert %d file(s) to %s?", file_count, target_label),
    { "&Yes", "&No" },
    { default = 2, highlight_group = "WarningMsg" }
  )

  if confirm_result ~= 1 then
    util.notify("Revert cancelled")
    return
  end

  local result = state.fs_monitor:revert_to_checkpoint(checkpoint_idx, state.checkpoints)

  if not result then
    util.notify("No changes were reverted")
    return
  end

  state.checkpoints = result.new_checkpoints
  state.all_changes = result.new_changes
  state.filtered_changes = result.new_changes

  if state.on_revert then state.on_revert(result.new_changes, result.new_checkpoints) end

  local summary = state.generate_summary(result.new_changes)
  state.summary = summary
  state.selected_file_idx = 1
  state.selected_checkpoint_idx = nil

  set_option("modifiable", true, { buf = state.files_buf })
  render.render_file_list(state.files_buf, state.ns, summary.files, summary.by_file, state.selected_file_idx)
  set_option("modifiable", false, { buf = state.files_buf })

  set_option("modifiable", true, { buf = state.checkpoints_buf })
  render.render_checkpoints(state.checkpoints_buf, state.ns, state.checkpoints, state.all_changes, nil)
  set_option("modifiable", false, { buf = state.checkpoints_buf })

  if #summary.files > 0 then
    pcall(api.nvim_win_set_cursor, state.files_win, { 1, 0 })
    M.update_preview(state, 1)
  else
    set_option("modifiable", true, { buf = state.right_buf })
    api.nvim_buf_set_lines(state.right_buf, 0, -1, false, { "", "No changes remaining", "" })
    set_option("modifiable", false, { buf = state.right_buf })
  end

  local msg = string.format("Reverted %d file(s) to %s", result.reverted_count, target_label)
  if result.error_count > 0 then msg = msg .. string.format(" (%d errors)", result.error_count) end
  util.notify(msg, result.error_count > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

---Revert ALL changes to original state
---@param state table
function M.revert_to_original(state)
  local ui = require("fs-monitor.utils.ui")
  local util = require("fs-monitor.utils.util")

  if not state.fs_monitor then
    util.notify("Cannot revert: no file system monitor available", vim.log.levels.ERROR)
    return
  end

  if #state.all_changes == 0 then
    util.notify("No changes to revert")
    return
  end

  local files_to_revert = {}
  for _, change in ipairs(state.all_changes) do
    files_to_revert[change.path] = true
  end
  local file_count = vim.tbl_count(files_to_revert)

  local confirm_result = ui.confirm(
    string.format("Revert ALL %d file(s) to original state? This cannot be undone.", file_count),
    { "&Yes", "&No" },
    { default = 2, highlight_group = "WarningMsg" }
  )

  if confirm_result ~= 1 then
    util.notify("Revert cancelled")
    return
  end

  local result = state.fs_monitor:revert_to_original(state.checkpoints)

  if not result then
    util.notify("No changes were reverted")
    return
  end

  M.close_windows(state)

  if state.on_revert then state.on_revert(result.new_changes, result.new_checkpoints) end

  local msg = string.format("Reverted %d file(s) to original state", result.reverted_count)
  if result.error_count > 0 then msg = msg .. string.format(" (%d errors)", result.error_count) end
  util.notify(msg, result.error_count > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

-- ============================================================================
-- VIEW TOGGLES
-- ============================================================================

---Generate help lines dynamically from keymaps config
---@return string[]
local function generate_help_lines()
  local cfg = get_config()
  local km = cfg.keymaps

  return {
    "# Help",
    "",
    "## General",
    string.format("- **%s**: %s", km.toggle_help.key, km.toggle_help.desc),
    string.format("- **%s** / **%s**: %s", km.close.key, km.close_alt.key, km.close.desc),
    string.format("- **%s**: %s", km.cycle_focus.key, km.cycle_focus.desc),
    string.format("- **%s**: %s", km.toggle_preview.key, km.toggle_preview.desc),
    string.format("- **%s**: %s", km.toggle_fullscreen.key, km.toggle_fullscreen.desc),
    "",
    "## Navigation",
    string.format("- **%s** / **%s**: Next/Prev file", km.next_file_alt.key, km.prev_file_alt.key),
    string.format("- **%s** / **%s**: Next/Prev hunk", km.next_hunk.key, km.prev_hunk.key),
    string.format("- **%s** / **%s**: Next/Prev file (preview)", km.next_file.key, km.prev_file.key),
    string.format("- **%s** / **%s**: %s", km.goto_file.key, km.goto_file_alt.key, km.goto_file.desc),
    "",
    "## Checkpoints",
    string.format("- **%s**: %s", km.view_checkpoint.key, km.view_checkpoint.desc),
    string.format("- **%s**: %s", km.view_cumulative.key, km.view_cumulative.desc),
    string.format("- **%s**: %s", km.revert_checkpoint.key, km.revert_checkpoint.desc),
    string.format("- **%s**: %s", km.reset_filter.key, km.reset_filter.desc),
    string.format("- **%s**: %s", km.revert_all.key, km.revert_all.desc),
  }
end

---Toggle help window
---@param state table
function M.toggle_help(state)
  local cfg = get_config()
  if state.help_win and api.nvim_win_is_valid(state.help_win) then
    pcall(api.nvim_win_close, state.help_win, true)
    if state.help_buf and api.nvim_buf_is_valid(state.help_buf) then
      pcall(api.nvim_buf_delete, state.help_buf, { force = true })
    end
    state.help_win = nil
    state.help_buf = nil
    return
  end

  local geom = state.get_geometry(state.is_fullscreen)

  state.help_buf = api.nvim_create_buf(false, true)
  set_option("buftype", "nofile", { buf = state.help_buf })
  set_option("bufhidden", "wipe", { buf = state.help_buf })
  set_option("filetype", "markdown", { buf = state.help_buf })

  local lines = generate_help_lines()
  api.nvim_buf_set_lines(state.help_buf, 0, -1, false, lines)

  state.help_win = api.nvim_open_win(state.help_buf, false, {
    relative = "editor",
    row = geom.row,
    col = geom.left_col,
    width = geom.left_w,
    height = geom.height,
    style = "minimal",
    border = "rounded",
    zindex = cfg.help_zindex,
  })

  vim.wo[state.help_win].wrap = true
  vim.wo[state.help_win].conceallevel = 2

  local close_keys = { cfg.keymaps.close.key, cfg.keymaps.close_alt.key, cfg.keymaps.toggle_help.key }
  for _, key in ipairs(close_keys) do
    vim.keymap.set("n", key, function()
      M.toggle_help(state)
    end, {
      buffer = state.help_buf,
      noremap = true,
      silent = true,
      nowait = true,
    })
  end
end

---Toggle preview-only mode
---@param state table
function M.toggle_preview_only(state)
  local g = state.get_geometry(state.is_fullscreen)

  if state.is_preview_only then
    update_win_config(state.files_win, {
      relative = "editor",
      row = g.row,
      col = g.left_col,
      width = g.left_w,
      height = g.files_h,
      hide = false,
    })
    update_win_config(state.checkpoints_win, {
      relative = "editor",
      row = g.checkpoints_row,
      col = g.left_col,
      width = g.left_w,
      height = g.checkpoints_h,
      hide = false,
    })
    update_win_config(state.right_win, {
      relative = "editor",
      row = g.row,
      col = g.right_col,
      width = g.right_w,
      height = g.height,
    })
    state.is_preview_only = false
  else
    local total_width = g.left_w + g.gap + g.right_w
    if state.is_fullscreen then total_width = vim.o.columns - 2 end

    update_win_config(state.files_win, { hide = true })
    update_win_config(state.checkpoints_win, { hide = true })
    update_win_config(state.right_win, {
      relative = "editor",
      row = g.row,
      col = state.is_fullscreen and 0 or g.left_col,
      width = total_width,
      height = g.height,
    })
    if api.nvim_win_is_valid(state.right_win) then api.nvim_set_current_win(state.right_win) end
    state.is_preview_only = true
  end
end

---Toggle fullscreen mode
---@param state table
function M.toggle_fullscreen(state)
  state.is_fullscreen = not state.is_fullscreen
  local g = state.get_geometry(state.is_fullscreen)

  if state.is_preview_only then
    local total_width = g.left_w + g.gap + g.right_w
    if state.is_fullscreen then total_width = vim.o.columns - 2 end
    update_win_config(state.right_win, {
      relative = "editor",
      row = g.row,
      col = state.is_fullscreen and 0 or g.left_col,
      width = total_width,
      height = g.height,
    })
  else
    update_win_config(state.files_win, {
      relative = "editor",
      row = g.row,
      col = g.left_col,
      width = g.left_w,
      height = g.files_h,
    })
    update_win_config(state.checkpoints_win, {
      relative = "editor",
      row = g.checkpoints_row,
      col = g.left_col,
      width = g.left_w,
      height = g.checkpoints_h,
    })
    update_win_config(state.right_win, {
      relative = "editor",
      row = g.row,
      col = g.right_col,
      width = g.right_w,
      height = g.height,
    })
  end
end

-- ============================================================================
-- BUFFER & WINDOW CREATION
-- ============================================================================

---Create all buffers for the diff viewer
---@return table buffers {files_buf, checkpoints_buf, right_buf}
function M.create_buffers()
  local files_buf = api.nvim_create_buf(false, true)
  set_option("buftype", "nofile", { buf = files_buf })
  set_option("bufhidden", "wipe", { buf = files_buf })
  set_option("filetype", "fs-monitor-diff-files", { buf = files_buf })

  local checkpoints_buf = api.nvim_create_buf(false, true)
  set_option("buftype", "nofile", { buf = checkpoints_buf })
  set_option("bufhidden", "wipe", { buf = checkpoints_buf })
  set_option("filetype", "fs-monitor-diff-checkpoints", { buf = checkpoints_buf })

  local right_buf = api.nvim_create_buf(false, true)
  set_option("buftype", "nofile", { buf = right_buf })
  set_option("bufhidden", "wipe", { buf = right_buf })
  set_option("modifiable", false, { buf = right_buf })
  api.nvim_buf_set_name(right_buf, "fs-monitor-diff")

  return {
    files_buf = files_buf,
    checkpoints_buf = checkpoints_buf,
    right_buf = right_buf,
  }
end

---Create all windows for the diff viewer
---@param buffers table Created buffers
---@param geom table Window geometry
---@return table windows {files_win, checkpoints_win, right_win}
function M.create_windows(buffers, geom)
  local ui = require("fs-monitor.utils.ui")
  local cfg = get_config()
  local km = cfg.keymaps

  local files_win = api.nvim_open_win(buffers.files_buf, true, {
    relative = "editor",
    row = geom.row,
    col = geom.left_col,
    width = geom.left_w,
    height = geom.files_h,
    style = "minimal",
    border = "rounded",
    zindex = cfg.zindex,
    title = cfg.titles.files,
    title_pos = "center",
  })

  local checkpoints_win = api.nvim_open_win(buffers.checkpoints_buf, false, {
    relative = "editor",
    row = geom.checkpoints_row,
    col = geom.left_col,
    width = geom.left_w,
    height = geom.checkpoints_h,
    style = "minimal",
    border = "rounded",
    zindex = cfg.zindex,
    title = cfg.titles.checkpoints,
    title_pos = "center",
  })

  local right_win = api.nvim_open_win(buffers.right_buf, false, {
    relative = "editor",
    row = geom.row,
    col = geom.right_col,
    width = geom.right_w,
    height = geom.height,
    style = "minimal",
    border = "rounded",
    zindex = cfg.zindex,
    title = cfg.titles.preview,
    title_pos = "center",
  })

  local win_opts = { number = false, relativenumber = false, wrap = false, cursorline = true, winfixbuf = true }
  for opt, val in pairs(win_opts) do
    vim.wo[files_win][opt] = val
    vim.wo[checkpoints_win][opt] = val
  end
  vim.wo[right_win].number = false
  vim.wo[right_win].relativenumber = false
  vim.wo[right_win].wrap = false
  vim.wo[right_win].cursorline = false
  vim.wo[right_win].scrollbind = false
  vim.wo[right_win].winfixbuf = true

  ui.set_winbar(checkpoints_win, {
    { keys = km.view_checkpoint.key, desc = km.view_checkpoint.desc },
    { keys = km.view_cumulative.key, desc = km.view_cumulative.desc },
    { keys = km.revert_checkpoint.key, desc = km.revert_checkpoint.desc },
  })

  ui.set_winbar(right_win, {
    { keys = km.toggle_preview.key, desc = km.toggle_preview.desc },
    { keys = km.toggle_fullscreen.key, desc = km.toggle_fullscreen.desc },
    { keys = km.next_hunk.key .. "/" .. km.prev_hunk.key, desc = "Hunk" },
    { keys = km.goto_file.key, desc = "File" },
    { keys = km.next_file.key .. "/" .. km.prev_file.key, desc = "Nav" },
    { keys = km.toggle_help.key, desc = "Help" },
  })

  return {
    files_win = files_win,
    checkpoints_win = checkpoints_win,
    right_win = right_win,
  }
end

-- ============================================================================
-- KEYMAP SETUP
-- ============================================================================

---Set a keymap on a buffer
---@param buf number
---@param key string
---@param callback function
---@param desc string
local function set_keymap(buf, key, callback, desc)
  vim.keymap.set("n", key, callback, {
    buffer = buf,
    noremap = true,
    silent = true,
    nowait = true,
    desc = desc,
  })
end

---Setup keymaps for all buffers
---@param state table
function M.setup_keymaps(state)
  local cfg = get_config()
  local km = cfg.keymaps

  local common_maps = {
    -- stylua: ignore start
    { km.close.key, function() M.close_windows(state) end, km.close.desc },
    { km.close_alt.key, function() M.close_windows(state) end, km.close_alt.desc },
    { km.toggle_help.key, function() M.toggle_help(state) end, km.toggle_help.desc },
    { km.toggle_preview.key, function() M.toggle_preview_only(state) end, km.toggle_preview.desc },
    { km.toggle_fullscreen.key, function() M.toggle_fullscreen(state) end, km.toggle_fullscreen.desc },
    -- stylua: ignore end
  }

  for _, map in ipairs(common_maps) do
    set_keymap(state.files_buf, map[1], map[2], map[3])
    set_keymap(state.checkpoints_buf, map[1], map[2], map[3])
  end

  local files_maps = {
    -- stylua: ignore start
    { km.next_file.key, function() M.navigate_files(state, 1) end, km.next_file.desc },
    { km.prev_file.key, function() M.navigate_files(state, -1) end, km.prev_file.desc },
    { km.next_file_alt.key, function() M.navigate_files(state, 1) end, km.next_file_alt.desc },
    { km.prev_file_alt.key, function() M.navigate_files(state, -1) end, km.prev_file_alt.desc },
    -- stylua: ignore end
    {
      km.cycle_focus.key,
      function()
        local current = api.nvim_get_current_win()
        if current == state.files_win then
          api.nvim_set_current_win(state.checkpoints_win)
        elseif current == state.checkpoints_win then
          api.nvim_set_current_win(state.right_win)
        else
          api.nvim_set_current_win(state.files_win)
        end
      end,
      km.cycle_focus.desc,
    },
  }

  for _, map in ipairs(files_maps) do
    set_keymap(state.files_buf, map[1], map[2], map[3])
  end

  local checkpoint_maps = {
    -- stylua: ignore start
    { km.reset_filter.key, function() M.reset_checkpoint_filter(state) end, km.reset_filter.desc },
    { km.revert_all.key, function() M.revert_to_original(state) end, km.revert_all.desc },
    { km.cycle_focus.key, function() api.nvim_set_current_win(state.right_win) end, km.cycle_focus.desc },
    -- stylua: ignore end
    {
      km.view_checkpoint.key,
      function()
        if #state.checkpoints == 0 then return end
        local cursor = api.nvim_win_get_cursor(state.checkpoints_win)
        local idx = cursor[1]
        if idx >= 1 and idx <= #state.checkpoints then M.apply_checkpoint_filter(state, idx, "differential") end
      end,
      km.view_checkpoint.desc,
    },
    {
      km.view_cumulative.key,
      function()
        if #state.checkpoints == 0 then return end
        local cursor = api.nvim_win_get_cursor(state.checkpoints_win)
        local idx = cursor[1]
        if idx >= 1 and idx <= #state.checkpoints then M.apply_checkpoint_filter(state, idx, "cumulative") end
      end,
      km.view_cumulative.desc,
    },
    {
      km.revert_checkpoint.key,
      function()
        if #state.checkpoints == 0 then return end
        local cursor = api.nvim_win_get_cursor(state.checkpoints_win)
        local idx = cursor[1]
        if idx >= 1 and idx <= #state.checkpoints then M.revert_to_checkpoint(state, idx) end
      end,
      km.revert_checkpoint.desc,
    },
  }

  for _, map in ipairs(checkpoint_maps) do
    set_keymap(state.checkpoints_buf, map[1], map[2], map[3])
  end

  state.right_keymaps = {
    -- stylua: ignore start
    { key = km.close.key, callback = function() M.close_windows(state) end, desc = km.close.desc },
    { key = km.close_alt.key, callback = function() M.close_windows(state) end, desc = km.close_alt.desc },
    { key = km.toggle_help.key, callback = function() M.toggle_help(state) end, desc = km.toggle_help.desc },
    { key = km.toggle_preview.key, callback = function() M.toggle_preview_only(state) end, desc = km.toggle_preview.desc },
    { key = km.toggle_fullscreen.key, callback = function() M.toggle_fullscreen(state) end, desc = km.toggle_fullscreen.desc, },
    { key = km.cycle_focus.key, callback = function() api.nvim_set_current_win(state.files_win) end, desc = km.cycle_focus.desc, },
    { key = km.next_file.key, callback = function() M.navigate_files(state, 1) end, desc = km.next_file.desc, },
    { key = km.prev_file.key, callback = function() M.navigate_files(state, -1) end, desc = km.prev_file.desc, },
    { key = km.goto_file.key, callback = function() M.jump_to_file_line(state) end, desc = km.goto_file.desc },
    { key = km.goto_file_alt.key, callback = function() M.jump_to_file_line(state) end, desc = km.goto_file_alt.desc },
    { key = km.next_hunk.key, callback = function() M.jump_next_hunk(state) end, desc = km.next_hunk.desc },
    { key = km.prev_hunk.key, callback = function() M.jump_prev_hunk(state) end, desc = km.prev_hunk.desc },
    -- stylua: ignore end
  }

  for _, keymap in ipairs(state.right_keymaps) do
    set_keymap(state.right_buf, keymap.key, keymap.callback, keymap.desc)
  end
end

-- ============================================================================
-- AUTOCMDS
-- ============================================================================

---Setup autocmds for the diff viewer
---@param state table
function M.setup_autocmds(state)
  local render = require("fs-monitor.diff.render")

  state.aug = api.nvim_create_augroup("FSMonitorDiff", { clear = true })

  api.nvim_create_autocmd({ "CursorMoved" }, {
    group = state.aug,
    buffer = state.files_buf,
    callback = function()
      if not api.nvim_win_is_valid(state.files_win) then return end
      local cursor = api.nvim_win_get_cursor(state.files_win)
      local line = cursor[1]
      if line > 0 and line <= #state.summary.files then
        state.selected_file_idx = line
        M.update_preview(state, line)
        render.render_file_list(state.files_buf, state.ns, state.summary.files, state.summary.by_file, line)
      end
    end,
  })

  api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = state.aug,
    buffer = state.files_buf,
    callback = function()
      M.close_windows(state)
    end,
  })

  api.nvim_create_autocmd({ "WinClosed" }, {
    group = state.aug,
    callback = function()
      local all_valid = api.nvim_win_is_valid(state.files_win)
        and api.nvim_win_is_valid(state.checkpoints_win)
        and api.nvim_win_is_valid(state.right_win)
      if not all_valid then M.close_windows(state) end
    end,
  })

  api.nvim_create_autocmd({ "VimResized" }, {
    group = state.aug,
    callback = function()
      local g = state.get_geometry(state.is_fullscreen)
      update_win_config(state.files_win, {
        relative = "editor",
        row = g.row,
        col = g.left_col,
        width = g.left_w,
        height = g.files_h,
      })
      update_win_config(state.checkpoints_win, {
        relative = "editor",
        row = g.checkpoints_row,
        col = g.left_col,
        width = g.left_w,
        height = g.checkpoints_h,
      })
      update_win_config(state.right_win, {
        relative = "editor",
        row = g.row,
        col = g.right_col,
        width = g.right_w,
        height = g.height,
      })
    end,
  })
end

return M
