---@module "fs-monitor.types"

---@class FSMonitor.Diff
local M = {}

local api = vim.api

---Get diff configuration
---@return FSMonitor.DiffConfig
local function get_config()
  return require("fs-monitor.config").ui_options
end

-- ============================================================================
-- GEOMETRY CALCULATIONS
-- ============================================================================

---Calculate window geometry for normal (non-fullscreen) mode
---@return table geometry
local function calculate_geometry()
  local max = math.max
  local floor = math.floor
  local cfg = get_config()
  local cols = vim.o.columns
  local lines = max(4, vim.o.lines - vim.o.cmdheight - 2)

  local right_w = max(40, floor(cols * cfg.right_width_ratio))
  local left_w = max(20, floor(cols * cfg.left_width_ratio))

  local total = left_w + cfg.gap + right_w

  if total > cols then
    local scale = cols / total
    left_w = max(cfg.min_left_width, floor(left_w * scale))
    right_w = max(cfg.min_right_width, floor(right_w * scale))
    total = left_w + cfg.gap + right_w
  end

  local height = max(cfg.min_height, floor(lines * cfg.height_ratio))
  local row = max(0, floor((vim.o.lines - height) / 2))
  local col = max(0, floor((cols - total) / 2))

  local checkpoints_h = max(5, floor(height * cfg.checkpoints_height_ratio))
  local files_h = max(3, height - checkpoints_h - cfg.left_gap)

  return {
    left_w = left_w,
    right_w = right_w,
    height = height,
    row = row,
    left_col = col,
    right_col = col + left_w + cfg.gap,
    gap = cfg.gap,
    files_h = files_h,
    checkpoints_h = checkpoints_h,
    checkpoints_row = row + files_h + cfg.left_gap,
  }
end

---Calculate maximized geometry (full editor screen)
---@return table geometry
local function get_maximized_geometry()
  local cfg = get_config()
  local max = math.max
  local floor = math.floor
  local cols = vim.o.columns
  local bottom = vim.o.cmdheight
  local top = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #api.nvim_list_tabpages() > 1)) and 1 or 0
  local height = vim.o.lines - top - bottom - 2

  local available_width = cols - cfg.gap - 4

  local left_w = floor(available_width * cfg.left_width_ratio / (cfg.left_width_ratio + cfg.right_width_ratio))
  local right_w = available_width - left_w

  local checkpoints_h = max(5, floor(height * cfg.checkpoints_height_ratio))
  local files_h = max(3, height - checkpoints_h - cfg.left_gap)

  return {
    left_w = left_w,
    right_w = right_w,
    height = height,
    row = top,
    left_col = 0,
    right_col = left_w + cfg.gap,
    gap = cfg.gap,
    files_h = files_h,
    checkpoints_h = checkpoints_h,
    checkpoints_row = top + files_h + cfg.left_gap,
  }
end

---Get geometry based on fullscreen state
---@param is_fullscreen boolean
---@return table geometry
local function get_geometry(is_fullscreen)
  return is_fullscreen and get_maximized_geometry() or calculate_geometry()
end

-- ============================================================================
-- SUMMARY GENERATION
-- ============================================================================

---Determine the net operation for a file across all changes in a session
---@param file_changes FSMonitor.Change[]
---@return FSMonitor.Change.Kind
local function determine_net_operation(file_changes)
  if #file_changes == 0 then return "modified" end

  local first_change = file_changes[1]
  local last_change = file_changes[#file_changes]

  for _, change in ipairs(file_changes) do
    if change.kind == "renamed" then return "renamed" end
  end

  local file_exists_now = last_change.kind ~= "deleted"
  local file_existed_before = first_change.kind ~= "created"

  -- Detect transient files (created during monitoring then deleted)
  if not file_exists_now and not file_existed_before then return "transient" end

  if not file_exists_now then
    return "deleted"
  elseif not file_existed_before then
    return "created"
  else
    return "modified"
  end
end

---Generate summary stats from changes
---@param changes FSMonitor.Change[]
---@return table summary
local function generate_summary(changes)
  local summary =
    { total = #changes, created = 0, modified = 0, deleted = 0, renamed = 0, transient = 0, files = {}, by_file = {} }

  for _, change in ipairs(changes) do
    if change.kind == "created" then
      summary.created = summary.created + 1
    elseif change.kind == "modified" then
      summary.modified = summary.modified + 1
    elseif change.kind == "deleted" then
      summary.deleted = summary.deleted + 1
    elseif change.kind == "renamed" then
      summary.renamed = summary.renamed + 1
    end

    if not summary.by_file[change.path] then
      summary.by_file[change.path] = {
        path = change.path,
        changes = {},
        net_operation = nil,
        created = 0,
        modified = 0,
        deleted = 0,
        renamed = 0,
        transient = 0,
        old_path = nil,
      }
      table.insert(summary.files, change.path)
    end

    local file_summary = summary.by_file[change.path]
    table.insert(file_summary.changes, change)
    file_summary[change.kind] = (file_summary[change.kind] or 0) + 1

    if change.kind == "renamed" and change.metadata and change.metadata.old_path then
      file_summary.old_path = change.metadata.old_path
    end
  end

  for _, filepath in ipairs(summary.files) do
    local file_summary = summary.by_file[filepath]
    file_summary.net_operation = determine_net_operation(file_summary.changes)

    if file_summary.net_operation == "transient" then summary.transient = summary.transient + 1 end
  end

  return summary
end

-- ============================================================================
-- MAIN ENTRY POINT
-- ============================================================================

---Main entry point for the diff viewer
---@param changes FSMonitor.Change[]
---@param checkpoints? FSMonitor.Checkpoint[]
---@param opts? { fs_monitor?: FSMonitor.Monitor, on_revert?: fun(changes: FSMonitor.Change[], checkpoints: FSMonitor.Checkpoint[]) }
function M.show(changes, checkpoints, opts)
  if not changes or #changes == 0 then
    require("fs-monitor.utils.util").notify("No file changes to display")
    return
  end

  checkpoints = checkpoints or {}
  opts = opts or {}

  local highlights = require("fs-monitor.utils.highlights")
  local ui = require("fs-monitor.utils.ui")
  local render = require("fs-monitor.diff.render")
  local actions = require("fs-monitor.diff.actions")

  highlights.setup()
  ui.create_background_window()

  local geom = calculate_geometry()
  local summary = generate_summary(changes)
  local current_win = api.nvim_get_current_win()

  local buffers = actions.create_buffers()
  local windows = actions.create_windows(buffers, geom)

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
    ns = api.nvim_create_namespace("fs_monitor_diff"),
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
    word_diff = get_config().word_diff,
    generate_summary = generate_summary,
    get_geometry = get_geometry,
  }

  render.new(state.files_buf, state.ns):render_file_list(summary.files, summary.by_file, state.selected_file_idx)
  render.new(state.checkpoints_buf, state.ns):render_checkpoints(checkpoints, changes, state.selected_checkpoint_idx)

  actions.setup_keymaps(state)
  actions.setup_autocmds(state)

  if #summary.files > 0 then
    pcall(api.nvim_win_set_cursor, state.files_win, { 1, 0 })
    actions.update_preview(state, 1)
  end

  return state
end

return M
