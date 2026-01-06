local api = vim.api

---@class FSMonitor.UI
local M = {}

-- Background window references for floating diff focus effect
M._background_win = nil
M._background_buf = nil

---Create a background window with winblend for focus effect
---@param opts? { dim?: number }
---@return number|nil winnr Background window number
function M.create_background_window(opts)
  opts = opts or {}
  local winblend = opts.dim or 25

  if M._background_win and api.nvim_win_is_valid(M._background_win) then return M._background_win end

  M._background_buf = api.nvim_create_buf(false, true)
  M._background_win = api.nvim_open_win(M._background_buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = vim.o.lines,
    style = "minimal",
    border = "none",
    focusable = false,
    noautocmd = true,
    zindex = 50,
  })

  -- Set winblend for dimming effect
  api.nvim_set_option_value("winblend", winblend, { win = M._background_win })

  return M._background_win
end

---Close the background window
---@return nil
function M.close_background_window()
  if M._background_win and api.nvim_win_is_valid(M._background_win) then
    pcall(api.nvim_win_close, M._background_win, true)
  end
  M._background_win = nil
  M._background_buf = nil
end

---A simple confirmation dialog using vim.fn.confirm
---@param prompt string The prompt message
---@param choices table Choices
---@param opts? { default?: number, highlight_group?: string } Additional options
---@return number The index of the selected choice (1-based), or 0 if cancelled
function M.confirm(prompt, choices, opts)
  opts = opts or { default = 1, highlight_group = "Question" }
  local formatted_choices = table.concat(choices, "\n")
  return vim.fn.confirm(prompt, formatted_choices, opts.default, opts.highlight_group)
end

---Set window bar with formatted hint items
---@param win number window handle
---@param items {keys: string, desc: string}[] array of key-description pairs
function M.set_winbar(win, items)
  if not api.nvim_win_is_valid(win) then return end

  local parts = {}
  for _, item in ipairs(items) do
    table.insert(parts, "%#FSMonitorSummary#" .. item.keys .. ":%* " .. item.desc)
  end

  local bar = table.concat(parts, "  |  ")
  vim.wo[win].winbar = "%=" .. bar .. "%="
end

return M
