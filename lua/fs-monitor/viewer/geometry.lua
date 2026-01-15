---@module "fs-monitor.types"

---@class FSMonitor.Viewer.Geometry
local M = {}

local api = vim.api

---Get viewer configuration
---@return FSMonitor.DiffConfig
local function get_config()
  return require("fs-monitor.config").ui_options
end

---Calculate window geometry for normal (non-fullscreen) mode
---@return table geometry
function M.calculate_normal()
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
function M.calculate_fullscreen()
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
function M.get(is_fullscreen)
  return is_fullscreen and M.calculate_fullscreen() or M.calculate_normal()
end

return M
