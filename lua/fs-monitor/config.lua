---@module "fs-monitor.types"

local M = {}

---@type FSMonitor.Config
M.defaults = {
  debounce_ms = 300,
  max_file_size = 1024 * 1024 * 2, -- 2MB
  max_prepopulate_files = 2000,
  max_depth = 6,
  max_cache_bytes = 1024 * 1024 * 50, -- 50MB
  ignore_patterns = {},
  respect_gitignore = true,
  debug = false,
  debug_file = nil,
}

---@type FSMonitor.DiffConfig
M.diff_defaults = {
  min_height = 10,
  min_left_width = 15,
  min_right_width = 30,
  left_width_ratio = 0.30,
  right_width_ratio = 0.65,
  height_ratio = 0.80,
  checkpoints_height_ratio = 0.30,
  gap = 2,
  left_gap = 2,
  zindex = 200,
  help_zindex = 201,

  icons = {
    created = "  ",
    deleted = " 󰺝",
    modified = " ",
    renamed = " ",
    checkpoint = " 󱘈",
    file_selector = "▶ ",
    sign = "▌",
    title_created = "",
    title_deleted = "󰺝",
    title_modified = "",
    title_renamed = "",
  },

  titles = {
    files = "  Changed Files ",
    checkpoints = " 󱘈 Checkpoints ",
    preview = " 󰈹 Diff Preview ", -- or 
  },

  keymaps = {
    close = { key = "q", desc = "Close viewer" },
    close_alt = { key = "<Esc>", desc = "Close viewer" },
    next_file = { key = "]f", desc = "Next file" },
    prev_file = { key = "[f", desc = "Previous file" },
    next_file_alt = { key = "j", desc = "Next file" },
    prev_file_alt = { key = "k", desc = "Previous file" },
    next_hunk = { key = "]h", desc = "Next hunk" },
    prev_hunk = { key = "[h", desc = "Previous hunk" },
    goto_file = { key = "gf", desc = "Go to file" },
    goto_hunk = { key = "gh", desc = "Go to hunk in file" },
    goto_hunk_alt = { key = "<CR>", desc = "Go to hunk in file" },
    cycle_focus = { key = "<Tab>", desc = "Cycle focus" },
    toggle_help = { key = "?", desc = "Toggle help" },
    toggle_preview = { key = "m", desc = "Preview only" },
    toggle_fullscreen = { key = "M", desc = "Fullscreen" },
    toggle_word_diff = { key = "gw", desc = "Toggle word diff" },
    revert_hunk = { key = "rh", desc = "Revert hunk" },
    reset_filter = { key = "r", desc = "Reset filter" },
    view_checkpoint = { key = "<CR>", desc = "View changes" },
    view_cumulative = { key = "a", desc = "Cumulative" },
    revert_checkpoint = { key = "R", desc = "Revert" },
    revert_all = { key = "X", desc = "Revert all" },
  },

  word_diff = true,
}

---@type FSMonitor.Config
M.options = vim.deepcopy(M.defaults)

---@type FSMonitor.DiffConfig
M.diff_options = vim.deepcopy(M.diff_defaults)

---Setup configuration with user options
---@param opts? { monitor?: FSMonitor.Config, diff?: FSMonitor.DiffConfig }
function M.setup(opts)
  opts = opts or {}

  if opts.monitor then M.options = vim.tbl_deep_extend("force", M.defaults, opts.monitor) end

  if opts.diff then M.diff_options = vim.tbl_deep_extend("force", M.diff_defaults, opts.diff) end
end

return M
