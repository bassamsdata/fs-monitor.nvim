---@module "fs-monitor.types"

---Internal module for revert operations
---@class FSMonitor.Viewer.Operations
local M = {}

local api = vim.api
local fmt = string.format

---Write reverted content to file
---@param filepath string Absolute path to file
---@param lines string[] File lines to write
---@return boolean success
---@return string? error
local function write_reverted_content(filepath, lines)
  local ok, err = pcall(vim.fn.writefile, lines, filepath)
  if not ok then return false, err end

  local bufnr = vim.fn.bufnr(filepath)
  if bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then vim.cmd("checktime " .. bufnr) end

  return true
end

---Update monitor changes after a revert
---@param monitor FSMonitor.Monitor
---@param filepath string Relative filepath
---@param new_content string New file content after revert
local function update_monitor_changes(monitor, filepath, new_content)
  local dominated_idx = nil
  local first_change_idx = nil
  local first_old_content = nil

  for i, change in ipairs(monitor.changes) do
    if change.path == filepath then
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
        if monitor.changes[i].path == filepath then table.remove(monitor.changes, i) end
      end
    else
      monitor.changes[dominated_idx].new_content = new_content
    end
  end
end

---Revert the hunk under the cursor
---@param viewer FSMonitor.Viewer
---@return FSMonitor.Viewer viewer
function M.revert_hunk(viewer)
  local util = require("fs-monitor.utils.util")
  local ui = require("fs-monitor.utils.ui")
  local updater = require("fs-monitor.viewer.updater")

  if not api.nvim_win_is_valid(viewer.right_win) then return viewer end
  if not viewer.hunk_ranges or #viewer.hunk_ranges == 0 then
    util.notify("No hunks to revert", vim.log.levels.WARN)
    return viewer
  end
  if not viewer.hunks or not viewer.current_filepath then return viewer end

  local cursor = api.nvim_win_get_cursor(viewer.right_win)
  local current_line = cursor[1]
  local hunk_idx = viewer:find_current_hunk(current_line)

  if not hunk_idx then
    util.notify("Cursor is not on a hunk", vim.log.levels.WARN)
    return viewer
  end

  local hunk = viewer.hunks[hunk_idx]
  if not hunk then return viewer end

  local confirm_result = ui.confirm(
    fmt("Revert hunk at line %d?", hunk.original_start),
    { "&Yes", "&No" },
    { default = 2, highlight_group = "WarningMsg" }
  )

  if confirm_result ~= 1 then
    util.notify("Revert cancelled")
    return viewer
  end

  local cwd = vim.fn.getcwd()
  local absolute_path = vim.fs.joinpath(cwd, viewer.current_filepath)

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

  local ok, err = write_reverted_content(absolute_path, new_lines)
  if not ok then
    util.notify(fmt("Failed to revert hunk: %s", err), vim.log.levels.ERROR)
    return viewer
  end

  util.notify("Hunk reverted successfully", vim.log.levels.INFO)

  viewer:invalidate_cache_for_file(viewer.current_filepath)

  local new_content = table.concat(new_lines, "\n")
  local monitor = viewer.fs_monitor
  if monitor then
    update_monitor_changes(monitor, viewer.current_filepath, new_content)

    viewer.all_changes = vim.deepcopy(monitor.changes)
    viewer.filtered_changes = viewer.all_changes
    viewer.summary = viewer:generate_summary(viewer.all_changes)

    updater.refresh_ui(viewer, { show_empty_message = true })

    if viewer.on_revert then viewer.on_revert(viewer.all_changes, viewer.checkpoints) end
  end

  return viewer
end

---Revert to state at a checkpoint using FSMonitor
---@param viewer FSMonitor.Viewer
---@param checkpoint_idx number
---@return FSMonitor.Viewer viewer
function M.revert_to_checkpoint(viewer, checkpoint_idx)
  local ui = require("fs-monitor.utils.ui")
  local util = require("fs-monitor.utils.util")
  local updater = require("fs-monitor.viewer.updater")

  if checkpoint_idx < 1 or checkpoint_idx > #viewer.checkpoints then return viewer end

  if checkpoint_idx == #viewer.checkpoints then
    util.notify("Already at final checkpoint - nothing to revert")
    return viewer
  end

  if not viewer.fs_monitor then
    util.notify("Cannot revert: no file system monitor available", vim.log.levels.ERROR)
    return viewer
  end

  local checkpoint = viewer.checkpoints[checkpoint_idx]
  local target_label = checkpoint.label or fmt("Checkpoint %d", checkpoint_idx)

  local files_to_revert = {}
  for _, change in ipairs(viewer.all_changes) do
    if change.timestamp > checkpoint.timestamp then files_to_revert[change.path] = true end
  end
  local file_count = vim.tbl_count(files_to_revert)

  if file_count == 0 then
    util.notify("No changes to revert")
    return viewer
  end

  local confirm_result = ui.confirm(
    fmt("Revert %d file(s) to %s?", file_count, target_label),
    { "&Yes", "&No" },
    { default = 2, highlight_group = "WarningMsg" }
  )

  if confirm_result ~= 1 then
    util.notify("Revert cancelled")
    return viewer
  end

  local result = viewer.fs_monitor:revert_to_checkpoint(checkpoint_idx, viewer.checkpoints)

  if not result then
    util.notify("No changes were reverted")
    return viewer
  end

  viewer:clear_preview_cache()

  viewer.checkpoints = result.new_checkpoints
  viewer.all_changes = result.new_changes
  viewer.filtered_changes = result.new_changes

  if viewer.on_revert then viewer.on_revert(result.new_changes, result.new_checkpoints) end

  local summary = viewer:generate_summary(result.new_changes)
  viewer.summary = summary
  viewer.selected_file_idx = 1
  viewer.selected_checkpoint_idx = nil

  updater.refresh_ui(viewer, { show_empty_message = true })

  local msg = fmt("Reverted %d file(s) to %s", result.reverted_count, target_label)
  if result.error_count > 0 then msg = msg .. fmt(" (%d errors)", result.error_count) end
  util.notify(msg, result.error_count > 0 and vim.log.levels.WARN or vim.log.levels.INFO)

  return viewer
end

---Revert ALL changes to original state
---@param viewer FSMonitor.Viewer
---@return FSMonitor.Viewer viewer
function M.revert_to_original(viewer)
  local ui = require("fs-monitor.utils.ui")
  local util = require("fs-monitor.utils.util")

  if not viewer.fs_monitor then
    util.notify("Cannot revert: no file system monitor available", vim.log.levels.ERROR)
    return viewer
  end

  if #viewer.all_changes == 0 then
    util.notify("No changes to revert")
    return viewer
  end

  local files_to_revert = {}
  for _, change in ipairs(viewer.all_changes) do
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
    return viewer
  end

  local result = viewer.fs_monitor:revert_to_original(viewer.checkpoints)

  if not result then
    util.notify("No changes were reverted")
    return viewer
  end

  viewer:clear_preview_cache()

  viewer:close()

  if viewer.on_revert then viewer.on_revert(result.new_changes, result.new_checkpoints) end

  local msg = fmt("Reverted %d file(s) to original state", result.reverted_count)
  if result.error_count > 0 then msg = msg .. fmt(" (%d errors)", result.error_count) end
  util.notify(msg, result.error_count > 0 and vim.log.levels.WARN or vim.log.levels.INFO)

  return viewer
end

return M
