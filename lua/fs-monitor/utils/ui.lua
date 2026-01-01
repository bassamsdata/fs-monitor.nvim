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

---@param bufnr nil|number
---@return number[]
function M.buf_list_wins(bufnr)
  local wins = {}

  if not bufnr or bufnr == 0 then bufnr = api.nvim_get_current_buf() end

  for _, winnr in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(winnr) and api.nvim_win_get_buf(winnr) == bufnr then table.insert(wins, winnr) end
  end

  return wins
end

---@param winnr? number
---@return nil
function M.scroll_to_end(winnr)
  winnr = winnr or 0
  local bufnr = api.nvim_win_get_buf(winnr)
  local lnum = api.nvim_buf_line_count(bufnr)
  local last_line = api.nvim_buf_get_lines(bufnr, -2, -1, true)[1]
  api.nvim_win_set_cursor(winnr, { lnum, api.nvim_strwidth(last_line) })
end

---@param bufnr nil|number
---@return nil
function M.buf_scroll_to_end(bufnr)
  for _, winnr in ipairs(M.buf_list_wins(bufnr or 0)) do
    M.scroll_to_end(winnr)
  end
end

---@param bufnr nil|number
---@return nil|number
function M.buf_get_win(bufnr)
  for _, winnr in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(winnr) == bufnr then return winnr end
  end
end

---Scroll the window to show a specific line without moving cursor
---@param bufnr number The buffer number
---@param line_num number The line number to scroll to (1-based)
function M.scroll_to_line(bufnr, line_num)
  local winnr = M.buf_get_win(bufnr)
  if not winnr then return end

  api.nvim_win_call(winnr, function()
    vim.cmd(":" .. tostring(line_num))
    vim.cmd("normal! zz")
  end)
end

---@return number
function M.get_editor_height()
  local editor_height = vim.o.lines - vim.o.cmdheight
  -- Subtract 1 if tabline is visible
  if vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #api.nvim_list_tabpages() > 1) then
    editor_height = editor_height - 1
  end
  -- Subtract 1 if statusline is visible
  if vim.o.laststatus >= 2 or (vim.o.laststatus == 1 and #api.nvim_tabpage_list_wins(0) > 1) then
    editor_height = editor_height - 1
  end
  return editor_height
end

---@param winnr number
---@param opts table
---@return table
function M.get_win_options(winnr, opts)
  local options = {}
  for k, _ in pairs(opts) do
    options[k] = api.nvim_get_option_value(k, { scope = "local", win = winnr })
  end
  return options
end

---@param winnr number
---@param opts table
---@return nil
function M.set_win_options(winnr, opts)
  for k, v in pairs(opts) do
    api.nvim_set_option_value(k, v, { scope = "local", win = winnr })
  end
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
