---@module "fs-monitor.types"

---@class FSMonitor.Viewer.Operations
local M = {}

local api = vim.api
local fmt = string.format

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

---Revert the hunk under the cursor
---@param state FSMonitor.Diff.State
---@param refresh_ui_fn function
function M.revert_current_hunk(state, refresh_ui_fn)
  local util = require("fs-monitor.utils.util")
  local ui = require("fs-monitor.utils.ui")

  if not api.nvim_win_is_valid(state.right_win) then return end
  if not state.hunk_ranges or #state.hunk_ranges == 0 then
    util.notify("No hunks to revert", vim.log.levels.WARN)
    return
  end
  if not state.hunks or not state.current_filepath then return end

  local cursor = api.nvim_win_get_cursor(state.right_win)
  local current_line = cursor[1]
  local hunk_idx = find_current_hunk(state.hunk_ranges, current_line)

  if not hunk_idx then
    util.notify("Cursor is not on a hunk", vim.log.levels.WARN)
    return
  end

  local hunk = state.hunks[hunk_idx]
  if not hunk then return end

  local confirm_result = ui.confirm(
    fmt("Revert hunk at line %d?", hunk.original_start),
    { "&Yes", "&No" },
    { default = 2, highlight_group = "WarningMsg" }
  )

  if confirm_result ~= 1 then
    util.notify("Revert cancelled")
    return
  end

  local cwd = vim.fn.getcwd()
  local absolute_path = vim.fs.joinpath(cwd, state.current_filepath)

  local file_content = table.concat(vim.fn.readfile(absolute_path), "\n")
  local file_lines = vim.split(file_content, "\n", { plain = true })

  local start_line = hunk.updated_start
  local end_line = start_line + hunk.updated_count - 1

  local new_lines = vim.deepcopy(file_lines)

  for i = end_line, start_line, -1 do
    table.remove(new_lines, i)
  end

  for i = #hunk.removed_lines, 1, -1 do
    table.insert(new_lines, start_line, hunk.removed_lines[i])
  end

  local ok, err = pcall(vim.fn.writefile, new_lines, absolute_path)
  if not ok then
    util.notify(fmt("Failed to revert hunk: %s", err), vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.fn.bufnr(absolute_path)
  if bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then vim.cmd("checktime " .. bufnr) end

  util.notify("Hunk reverted successfully", vim.log.levels.INFO)

  local new_content = table.concat(new_lines, "\n")
  local monitor = state.fs_monitor
  if monitor then
    local dominated_idx = nil
    local first_change_idx = nil
    local first_old_content = nil

    for i, change in ipairs(monitor.changes) do
      if change.path == state.current_filepath then
        if not first_change_idx then
          first_change_idx = i
          first_old_content = change.old_content
        end
        dominated_idx = i
      end
    end

    if dominated_idx then
      local original_content = first_old_content or ""

      if new_content == original_content then
        for i = #monitor.changes, 1, -1 do
          if monitor.changes[i].path == state.current_filepath then table.remove(monitor.changes, i) end
        end
      else
        monitor.changes[dominated_idx].new_content = new_content
      end
    end

    state.all_changes = vim.deepcopy(monitor.changes)
    state.filtered_changes = state.all_changes
    state.summary = state.generate_summary(state.all_changes)

    refresh_ui_fn(state, { show_empty_message = true })

    if state.on_revert then state.on_revert(state.all_changes, state.checkpoints) end
  end
end

---Revert to state at a checkpoint using FSMonitor
---@param state FSMonitor.Diff.State
---@param checkpoint_idx number
---@param refresh_ui_fn function
function M.revert_to_checkpoint(state, checkpoint_idx, refresh_ui_fn)
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
  local target_label = checkpoint.label or fmt("Checkpoint %d", checkpoint_idx)

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
    fmt("Revert %d file(s) to %s?", file_count, target_label),
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

  refresh_ui_fn(state, { show_empty_message = true })

  local msg = fmt("Reverted %d file(s) to %s", result.reverted_count, target_label)
  if result.error_count > 0 then msg = msg .. fmt(" (%d errors)", result.error_count) end
  util.notify(msg, result.error_count > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

---Revert ALL changes to original state
---@param state FSMonitor.Diff.State
---@param close_windows_fn function
function M.revert_to_original(state, close_windows_fn)
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
    fmt("Revert ALL %d file(s) to original state? This cannot be undone.", file_count),
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

  close_windows_fn(state)

  if state.on_revert then state.on_revert(result.new_changes, result.new_checkpoints) end

  local msg = fmt("Reverted %d file(s) to original state", result.reverted_count)
  if result.error_count > 0 then msg = msg .. fmt(" (%d errors)", result.error_count) end
  util.notify(msg, result.error_count > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

return M
