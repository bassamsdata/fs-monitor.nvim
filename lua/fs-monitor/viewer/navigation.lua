---@module "fs-monitor.types"

---@class FSMonitor.Viewer.Navigation
local M = {}

local api = vim.api
local set_option = vim.api.nvim_set_option_value
local fmt = string.format

---Get viewer configuration
---@return FSMonitor.DiffConfig
local function get_config()
  return require("fs-monitor.config").ui_options
end

---Reapply keymaps to right buffer (needed after filetype changes)
---@param state FSMonitor.Diff.State
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
---@param state FSMonitor.Diff.State
---@param idx number
function M.update_preview(state, idx)
  local render = require("fs-monitor.viewer.render")
  local hunk_calculator = require("fs-monitor.viewer.hunk_calculator")
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
  elseif net_operation == "deleted" or net_operation == "transient" then
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

  local hunks = hunk_calculator.calculate_hunks(old_lines, new_lines, 3)
  local ft = vim.filetype.match({ filename = filepath }) or ""

  set_option("modifiable", true, { buf = state.right_buf })
  api.nvim_buf_clear_namespace(state.right_buf, state.ns, 0, -1)
  local _, line_mappings, hunk_ranges = render.new(state.right_buf, state.ns):render_diff(hunks, state.word_diff)
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
    local title_icon = cfg.icons.modified
    if net_operation == "created" then
      title_icon = cfg.icons.created
    elseif net_operation == "deleted" then
      title_icon = cfg.icons.deleted
    elseif net_operation == "renamed" then
      title_icon = cfg.icons.renamed
    elseif net_operation == "transient" then
      title_icon = cfg.icons.transient
    end
    local title_name = vim.fn.fnamemodify(filepath, ":t")
    if net_operation == "renamed" and file_info.old_path then
      local old_name = vim.fn.fnamemodify(file_info.old_path, ":t")
      title_name = old_name .. " → " .. title_name
    end

    local hunk_count_str = ""
    if #hunks > 0 then hunk_count_str = fmt(" [%d %s]", #hunks, util.pluralize(#hunks, "hunk")) end

    api.nvim_win_set_config(state.right_win, {
      title = fmt(" %s %s%s ", title_icon, title_name, hunk_count_str),
      title_pos = "center",
    })
  end
end

---Navigate to next/previous file
---@param state FSMonitor.Diff.State
---@param direction number
function M.navigate_files(state, direction)
  local render = require("fs-monitor.viewer.render")

  if #state.summary.files == 0 then return end

  state.selected_file_idx = state.selected_file_idx or 1

  local new_file_idx = state.selected_file_idx + direction
  new_file_idx = math.max(1, math.min(new_file_idx, #state.summary.files))

  state.selected_file_idx = new_file_idx

  if api.nvim_win_is_valid(state.files_win) then
    pcall(api.nvim_win_set_cursor, state.files_win, { state.selected_file_idx, 0 })
  end

  M.update_preview(state, new_file_idx)
  set_option("modifiable", true, { buf = state.files_buf })
  render.new(state.files_buf, state.ns):render_file_list(state.summary.files, state.summary.by_file, new_file_idx)
  set_option("modifiable", false, { buf = state.files_buf })
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

---Get first content line of a hunk (skip the @@ header line)
---@param range table
---@return number
local function get_hunk_content_line(range)
  return range.start_line + 4
end

---Jump to next hunk in diff preview
---@param state FSMonitor.Diff.State
function M.jump_next_hunk(state)
  if not api.nvim_win_is_valid(state.right_win) then return end
  if not state.hunk_ranges or #state.hunk_ranges == 0 then return end

  local cursor = api.nvim_win_get_cursor(state.right_win)
  local current_line = cursor[1]

  for _, range in ipairs(state.hunk_ranges) do
    if range.start_line > current_line then
      api.nvim_win_set_cursor(state.right_win, { get_hunk_content_line(range), 0 })
      vim.cmd("normal! zz")
      return
    end
  end

  api.nvim_win_set_cursor(state.right_win, { get_hunk_content_line(state.hunk_ranges[1]), 0 })
  vim.cmd("normal! zz")
end

---Jump to previous hunk in diff preview
---@param state FSMonitor.Diff.State
function M.jump_prev_hunk(state)
  if not api.nvim_win_is_valid(state.right_win) then return end
  if not state.hunk_ranges or #state.hunk_ranges == 0 then return end

  local cursor = api.nvim_win_get_cursor(state.right_win)
  local current_line = cursor[1]

  local current_hunk_idx = find_current_hunk(state.hunk_ranges, current_line)

  if current_hunk_idx then
    if current_hunk_idx > 1 then
      api.nvim_win_set_cursor(state.right_win, { get_hunk_content_line(state.hunk_ranges[current_hunk_idx - 1]), 0 })
      vim.cmd("normal! zz")
      return
    end
  else
    for i = #state.hunk_ranges, 1, -1 do
      if state.hunk_ranges[i].start_line < current_line then
        api.nvim_win_set_cursor(state.right_win, { get_hunk_content_line(state.hunk_ranges[i]), 0 })
        vim.cmd("normal! zz")
        return
      end
    end
  end

  api.nvim_win_set_cursor(state.right_win, { get_hunk_content_line(state.hunk_ranges[#state.hunk_ranges]), 0 })
  vim.cmd("normal! zz")
end

---Open file in editor with optional line number
---@param filepath string Absolute path to file
---@param line? number Optional line number to jump to
local function open_file_at_line(filepath, line)
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
---@param state FSMonitor.Diff.State
---@param close_windows_fn function
function M.goto_file_in_editor(state, close_windows_fn)
  local filepath = state.summary.files[state.selected_file_idx]
  if not filepath then return end

  local cwd = vim.fn.getcwd()
  local absolute_path = vim.fs.joinpath(cwd, filepath)

  close_windows_fn(state, false)
  open_file_at_line(absolute_path)
end

---Jump from diff preview line to actual file line
---@param state FSMonitor.Diff.State
---@param close_windows_fn function
function M.jump_to_file_line(state, close_windows_fn)
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
    util.notify(fmt("File not found: %s", state.current_filepath), vim.log.levels.WARN)
    return
  end

  close_windows_fn(state, false)
  open_file_at_line(absolute_path, target_line)
end

---Filter changes based on checkpoint and mode
---@param state FSMonitor.Diff.State
---@param checkpoint_idx number
---@param mode? "cumulative"|"differential"
---@param refresh_ui_fn function
function M.apply_checkpoint_filter(state, checkpoint_idx, mode, refresh_ui_fn)
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
  refresh_ui_fn(state, { selected_checkpoint_idx = checkpoint_idx, show_empty_message = true })
end

---Reset to show all changes
---@param state FSMonitor.Diff.State
---@param refresh_ui_fn function
function M.reset_checkpoint_filter(state, refresh_ui_fn)
  state.selected_checkpoint_idx = nil
  state.filtered_changes = state.all_changes
  state.summary = state.generate_summary(state.all_changes)
  state.selected_file_idx = 1

  refresh_ui_fn(state)
end

return M
