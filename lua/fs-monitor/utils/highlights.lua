local M = {}

local api = vim.api

---Blend two hex colors
---@param fg string foreground color (hex format like "#rrggbb")
---@param bg string background color (hex format like "#rrggbb")
---@param alpha number number between 0 and 1. 0 results in bg, 1 results in fg
---@return string blended hex color
function M.blend(fg, bg, alpha)
  local bg_rgb = {
    tonumber(bg:sub(2, 3), 16),
    tonumber(bg:sub(4, 5), 16),
    tonumber(bg:sub(6, 7), 16),
  }
  local fg_rgb = {
    tonumber(fg:sub(2, 3), 16),
    tonumber(fg:sub(4, 5), 16),
    tonumber(fg:sub(6, 7), 16),
  }
  local blend_channel = function(i)
    local ret = (alpha * fg_rgb[i] + ((1 - alpha) * bg_rgb[i]))
    return math.floor(math.min(math.max(0, ret), 255) + 0.5)
  end
  return string.format("#%02x%02x%02x", blend_channel(1), blend_channel(2), blend_channel(3))
end

---Get normal background color from colorscheme
---@return string hex color
function M.get_normal_bg()
  local normal_hl = api.nvim_get_hl(0, { name = "Normal" })
  if normal_hl.bg then return string.format("#%06x", normal_hl.bg) end
  return vim.o.background == "dark" and "#1e1e2e" or "#f5f5f5"
end

---Get background color from a highlight group
---@param hl_name string highlight group name
---@return string|nil hex color or nil if not found
function M.get_hl_bg(hl_name)
  local hl = api.nvim_get_hl(0, { name = hl_name, link = false })
  if hl.bg then return string.format("#%06x", hl.bg) end
  return nil
end

---Define highlight groups for diff viewer
local function define_highlights()
  local normal_bg = M.get_normal_bg()

  local add_fg = "#a6e3a1"
  local delete_fg = "#f38ba8"
  local change_fg = "#f9e2af"
  local context_fg = "#6c7086"

  local diff_add_bg = M.get_hl_bg("DiffAdd") or M.blend(add_fg, normal_bg, 0.2)
  local diff_delete_bg = M.get_hl_bg("DiffDelete") or M.blend(delete_fg, normal_bg, 0.2)

  local hl_groups = {
    FSMonitorAdd = { bg = diff_add_bg, default = true },
    FSMonitorDelete = { bg = diff_delete_bg, default = true },
    FSMonitorChange = { link = "DiffChange", default = true },
    FSMonitorText = { link = "DiffText", default = true },
    FSMonitorContext = { link = "DiffChange", default = true },
    FSMonitorAddLineNr = {
      fg = add_fg,
      bg = M.blend(add_fg, normal_bg, 0.1),
      default = true,
    },
    FSMonitorDeleteLineNr = {
      fg = delete_fg,
      bg = M.blend(delete_fg, normal_bg, 0.1),
      default = true,
    },
    FSMonitorChangeLineNr = {
      fg = change_fg,
      bg = M.blend(change_fg, normal_bg, 0.1),
      default = true,
    },
    FSMonitorContextLineNr = {
      fg = context_fg,
      bg = M.blend(context_fg, normal_bg, 0.1),
      default = true,
    },
    FSMonitorHeader = { link = "Title", default = true },
    FSMonitorSummary = { link = "Comment", default = true },
  }

  for name, opts in pairs(hl_groups) do
    api.nvim_set_hl(0, name, opts)
  end
end

---@type number|nil
local augroup = nil

---Setup highlight groups and ColorScheme autocmd
function M.setup()
  define_highlights()

  if not augroup then
    augroup = api.nvim_create_augroup("FSMonitorHighlights", { clear = true })
    api.nvim_create_autocmd("ColorScheme", {
      group = augroup,
      callback = define_highlights,
    })
  end
end

return M
