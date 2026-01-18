---@module "fs-monitor.types"

---Worktree pane for committing session changes
---@class FSMonitor.WorktreePane
local M = {}

local api = vim.api
local set_option = vim.api.nvim_set_option_value
local util = require("fs-monitor.utils.util")
local log = require("fs-monitor.log")

---@class FSMonitor.WorktreePaneState
---@field buf number Buffer handle
---@field win number Window handle
---@field ns number Namespace ID
---@field session FSMonitor.Session Current session
---@field selected_files table<string, boolean> Map of filepath to selection state
---@field selected_hunks table<string, table<number, boolean>> Map of filepath to hunk selections
---@field commit_message string Current commit message
---@field commit_message_lines number[] Line numbers for commit message area
---@field ui_mode "all"|"selected" Current UI mode

---Create a new worktree pane instance
---@param session FSMonitor.Session
---@return FSMonitor.WorktreePaneState|nil
local function create_pane(session)
  if not session or not session.monitor then
    util.notify("Invalid session", vim.log.levels.WARN)
    return nil
  end

  local changes = session.monitor:get_all_changes()
  if #changes == 0 then
    util.notify("No changes to commit", vim.log.levels.WARN)
    return nil
  end

  local buf = api.nvim_create_buf(false, true)
  set_option("buftype", "nofile", { buf = buf })
  set_option("bufhidden", "wipe", { buf = buf })
  set_option("filetype", "fs-monitor-worktree", { buf = buf })
  set_option("modifiable", false, { buf = buf })

  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.7)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    zindex = 250,
    title = " Commit Changes ",
    title_pos = "center",
  })

  if api.nvim_win_is_valid(win) then
    vim.wo[win].cursorline = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
  end

  local state = {
    buf = buf,
    win = win,
    ns = api.nvim_create_namespace("fs_monitor_worktree_pane"),
    session = session,
    selected_files = {},
    selected_hunks = {},
    commit_message = "",
    commit_message_lines = {},
    ui_mode = "all",
  }

  for _, change in ipairs(changes) do
    state.selected_files[change.path] = true
  end

  return state
end

---Render the worktree pane UI
---@param state FSMonitor.WorktreePaneState
local function render_ui(state)
  if not api.nvim_buf_is_valid(state.buf) then return end

  local lines = {}
  local highlights = {}

  table.insert(lines, "")
  table.insert(lines, " Commit Message:")
  state.commit_message_lines = {}

  local msg_start = #lines + 1
  if state.commit_message == "" then
    table.insert(lines, " [Enter commit message]")
    table.insert(highlights, { line = #lines - 1, hl_group = "Comment", col_start = 0, col_end = -1 })
  else
    for msg_line in state.commit_message:gmatch("[^\n]+") do
      table.insert(lines, " " .. msg_line)
      table.insert(state.commit_message_lines, #lines)
    end
  end

  table.insert(lines, "")
  table.insert(lines, "")
  table.insert(lines, " Changed Files:")
  table.insert(lines, "")

  local changes = state.session.monitor:get_all_changes()
  for i, change in ipairs(changes) do
    local selected = state.selected_files[change.path]
    local checkbox = selected and "[x]" or "[ ]"
    local icon = " "

    if change.kind == "created" then
      icon = ""
    elseif change.kind == "deleted" then
      icon = "󰺝"
    elseif change.kind == "modified" then
      icon = ""
    elseif change.kind == "renamed" then
      icon = ""
    end

    local line_text = string.format(" %s %s %s", checkbox, icon, change.path)
    table.insert(lines, line_text)

    local checkbox_hl = selected and "String" or "Comment"
    table.insert(highlights, { line = #lines - 1, hl_group = checkbox_hl, col_start = 1, col_end = 4 })

    local kind_hl = "Normal"
    if change.kind == "created" then
      kind_hl = "DiffAdd"
    elseif change.kind == "deleted" then
      kind_hl = "DiffDelete"
    elseif change.kind == "modified" then
      kind_hl = "DiffChange"
    end
    table.insert(highlights, { line = #lines - 1, hl_group = kind_hl, col_start = 5, col_end = 7 })
  end

  table.insert(lines, "")
  table.insert(lines, "")
  table.insert(lines, " Actions:")
  table.insert(lines, "  <Space> Toggle file selection")
  table.insert(lines, "  i       Edit commit message")
  table.insert(lines, "  ca      Commit all files")
  table.insert(lines, "  cs      Commit selected files")
  table.insert(lines, "  q       Close")

  set_option("modifiable", true, { buf = state.buf })
  api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  set_option("modifiable", false, { buf = state.buf })

  api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  for _, hl in ipairs(highlights) do
    api.nvim_buf_add_highlight(state.buf, state.ns, hl.hl_group, hl.line, hl.col_start, hl.col_end)
  end
end

---Toggle file selection at cursor
---@param state FSMonitor.WorktreePaneState
local function toggle_selection(state)
  local cursor = api.nvim_win_get_cursor(state.win)
  local line_num = cursor[1]

  local change_idx = nil
  local line_offset = 0

  local changes = state.session.monitor:get_all_changes()
  for i = 1, #api.nvim_buf_get_lines(state.buf, 0, -1, false) do
    local line_text = api.nvim_buf_get_lines(state.buf, i - 1, i, false)[1]
    if line_text:match("^%s*%[.%]") then
      line_offset = line_offset + 1
      if i == line_num then
        change_idx = line_offset
        break
      end
    end
  end

  if change_idx and change_idx <= #changes then
    local change = changes[change_idx]
    state.selected_files[change.path] = not state.selected_files[change.path]
    render_ui(state)
    api.nvim_win_set_cursor(state.win, { line_num, 0 })
  end
end

---Edit commit message
---@param state FSMonitor.WorktreePaneState
local function edit_commit_message(state)
  vim.ui.input({
    prompt = "Commit message: ",
    default = state.commit_message,
  }, function(input)
    if input then
      state.commit_message = input
      render_ui(state)
    end
  end)
end

---Get selected changes
---@param state FSMonitor.WorktreePaneState
---@return FSMonitor.Change[]
local function get_selected_changes(state)
  local selected = {}
  local changes = state.session.monitor:get_all_changes()
  for _, change in ipairs(changes) do
    if state.selected_files[change.path] then table.insert(selected, change) end
  end
  return selected
end

---Commit changes to worktree
---@param state FSMonitor.WorktreePaneState
---@param mode "all"|"selected"
local function commit_changes(state, mode)
  if state.commit_message == "" then
    util.notify("Please enter a commit message", vim.log.levels.WARN)
    return
  end

  local all_changes = state.session.monitor:get_all_changes()
  local changes = mode == "all" and all_changes or get_selected_changes(state)

  if #changes == 0 then
    util.notify("No files selected", vim.log.levels.WARN)
    return
  end

  api.nvim_win_close(state.win, true)

  local worktree = require("fs-monitor.worktree")
  worktree.create_worktree(state.session.id, function(success, worktree_path)
    if not success then return end

    vim.system({ "git", "add", "." }, { cwd = worktree_path, text = true }, function(add_result)
      if add_result.code ~= 0 then
        util.notify("Failed to stage files: " .. (add_result.stderr or ""), vim.log.levels.ERROR)
        return
      end

      vim.system(
        { "git", "commit", "-m", state.commit_message },
        { cwd = worktree_path, text = true },
        function(commit_result)
          if commit_result.code ~= 0 then
            util.notify("Failed to commit: " .. (commit_result.stderr or ""), vim.log.levels.ERROR)
            return
          end

          util.notify(
            string.format(
              "Successfully committed %d file%s to worktree\n%s",
              #changes,
              #changes == 1 and "" or "s",
              worktree_path
            ),
            vim.log.levels.INFO
          )
        end
      )
    end)
  end)
end

---Setup keymaps for the worktree pane
---@param state FSMonitor.WorktreePaneState
local function setup_keymaps(state)
  local opts = { buffer = state.buf, noremap = true, silent = true, nowait = true }

  vim.keymap.set("n", "q", function()
    api.nvim_win_close(state.win, true)
  end, vim.tbl_extend("force", opts, { desc = "Close worktree pane" }))

  vim.keymap.set("n", "<Esc>", function()
    api.nvim_win_close(state.win, true)
  end, vim.tbl_extend("force", opts, { desc = "Close worktree pane" }))

  vim.keymap.set("n", "<Space>", function()
    toggle_selection(state)
  end, vim.tbl_extend("force", opts, { desc = "Toggle file selection" }))

  vim.keymap.set("n", "i", function()
    edit_commit_message(state)
  end, vim.tbl_extend("force", opts, { desc = "Edit commit message" }))

  vim.keymap.set("n", "ca", function()
    commit_changes(state, "all")
  end, vim.tbl_extend("force", opts, { desc = "Commit all files" }))

  vim.keymap.set("n", "cs", function()
    commit_changes(state, "selected")
  end, vim.tbl_extend("force", opts, { desc = "Commit selected files" }))
end

---Show the worktree pane for a session
---@param session_id string
function M.show(session_id)
  local fs_monitor = require("fs-monitor")
  local session = fs_monitor.get_session(session_id)

  if not session then
    util.notify(string.format("Session not found: %s", session_id), vim.log.levels.ERROR)
    return
  end

  local state = create_pane(session)
  if not state then return end

  render_ui(state)
  setup_keymaps(state)
end

---Show the worktree pane for the current viewer session
---@param viewer FSMonitor.Viewer
function M.show_from_viewer(viewer)
  if not viewer.fs_monitor then
    util.notify("No active session in viewer", vim.log.levels.WARN)
    return
  end

  local session_id = viewer.fs_monitor.session_id
  if not session_id then
    util.notify("No active session in viewer", vim.log.levels.WARN)
    return
  end

  M.show(session_id)
end

return M
