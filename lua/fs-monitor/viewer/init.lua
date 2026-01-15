---@module "fs-monitor.types"

---@class FSMonitor.Viewer
local M = {}

local api = vim.api

---Main entry point for the diff viewer
---@param changes FSMonitor.Change[]
---@param checkpoints? FSMonitor.Checkpoint[]
---@param opts? { fs_monitor?: FSMonitor.Monitor, on_revert?: fun(changes: FSMonitor.Change[], checkpoints: FSMonitor.Checkpoint[]) }
---@return table|nil state
function M.show(changes, checkpoints, opts)
  if not changes or #changes == 0 then
    require("fs-monitor.utils.util").notify("No file changes to display")
    return
  end

  checkpoints = checkpoints or {}
  opts = opts or {}

  local highlights = require("fs-monitor.utils.highlights")
  local ui_utils = require("fs-monitor.utils.ui")
  local geometry = require("fs-monitor.viewer.geometry")
  local state_module = require("fs-monitor.viewer.state")
  local render = require("fs-monitor.viewer.render")
  local ui = require("fs-monitor.viewer.ui")
  local navigation = require("fs-monitor.viewer.navigation")

  highlights.setup()
  ui_utils.create_background_window()

  local geom = geometry.calculate_normal()
  local summary = state_module.generate_summary(changes)
  local current_win = api.nvim_get_current_win()

  local buffers = ui.create_buffers()
  local windows = ui.create_windows(buffers, geom)

  local state = {
    original_win = current_win,
    files_buf = buffers.files_buf,
    checkpoints_buf = buffers.checkpoints_buf,
    right_buf = buffers.right_buf,
    files_win = windows.files_win,
    checkpoints_win = windows.checkpoints_win,
    right_win = windows.right_win,
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
    generate_summary = state_module.generate_summary,
    get_geometry = geometry.get,
  }

  render.new(state.files_buf, state.ns):render_file_list(summary.files, summary.by_file, state.selected_file_idx)
  render.new(state.checkpoints_buf, state.ns):render_checkpoints(checkpoints, changes, state.selected_checkpoint_idx)

  ui.setup_keymaps(state)
  ui.setup_autocmds(state)

  if #summary.files > 0 then
    pcall(api.nvim_win_set_cursor, state.files_win, { 1, 0 })
    navigation.update_preview(state, 1)
  end

  return state
end

return M
