---@module "fs-monitor.types"

---@class FSMonitor.Viewer.UI
local M = {}

local api = vim.api
local set_option = vim.api.nvim_set_option_value
local fmt = string.format

---Get viewer configuration
---@return FSMonitor.DiffConfig
local function get_config()
  return require("fs-monitor.config").ui_options
end

---Update window configuration safely
---@param win number
---@param config table
local function update_win_config(win, config)
  if api.nvim_win_is_valid(win) then pcall(api.nvim_win_set_config, win, config) end
end

---Refresh all UI panels after state changes
---@param state FSMonitor.Diff.State
---@param opts? { selected_checkpoint_idx?: number|nil, show_empty_message?: boolean }
function M.refresh_ui(state, opts)
  opts = opts or {}
  local render = require("fs-monitor.viewer.render")
  local navigation = require("fs-monitor.viewer.navigation")

  set_option("modifiable", true, { buf = state.files_buf })
  render
    .new(state.files_buf, state.ns)
    :render_file_list(state.summary.files, state.summary.by_file, state.selected_file_idx)
  set_option("modifiable", false, { buf = state.files_buf })

  set_option("modifiable", true, { buf = state.checkpoints_buf })
  render
    .new(state.checkpoints_buf, state.ns)
    :render_checkpoints(state.checkpoints, state.all_changes, opts.selected_checkpoint_idx)
  set_option("modifiable", false, { buf = state.checkpoints_buf })

  if #state.summary.files > 0 then
    if state.selected_file_idx > #state.summary.files then state.selected_file_idx = #state.summary.files end
    if state.selected_file_idx < 1 then state.selected_file_idx = 1 end
    pcall(api.nvim_win_set_cursor, state.files_win, { state.selected_file_idx, 0 })
    navigation.update_preview(state, state.selected_file_idx)
  elseif opts.show_empty_message then
    set_option("modifiable", true, { buf = state.right_buf })
    api.nvim_buf_set_lines(state.right_buf, 0, -1, false, { "", "No changes remaining", "" })
    set_option("modifiable", false, { buf = state.right_buf })
  end
end

---Close all windows
---@param state FSMonitor.Diff.State
---@param restore_focus? boolean Whether to restore focus to original window (default true)
function M.close_windows(state, restore_focus)
  if restore_focus == nil then restore_focus = true end

  if state.aug then
    pcall(api.nvim_del_augroup_by_id, state.aug)
    state.aug = nil
  end

  local windows = { state.files_win, state.checkpoints_win, state.right_win, state.help_win }
  for _, win in ipairs(windows) do
    if win and api.nvim_win_is_valid(win) then pcall(api.nvim_win_close, win, true) end
  end

  local buffers = { state.files_buf, state.checkpoints_buf, state.right_buf, state.help_buf }
  for _, buf in ipairs(buffers) do
    if buf and api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end
  end

  local ui_utils = require("fs-monitor.utils.ui")
  ui_utils.close_background_window()

  if restore_focus and state.original_win and api.nvim_win_is_valid(state.original_win) then
    pcall(api.nvim_set_current_win, state.original_win)
  end
end

---Generate help lines dynamically from keymaps config
---@return string[]
local function generate_help_lines()
  local cfg = get_config()
  local km = cfg.keymaps

  return {
    "## General",
    fmt("- **%s**: %s", km.toggle_help.key, km.toggle_help.desc),
    fmt("- **%s** / **%s**: %s", km.close.key, km.close_alt.key, km.close.desc),
    fmt("- **%s**: %s", km.cycle_focus.key, km.cycle_focus.desc),
    fmt("- **%s**: %s", km.toggle_preview.key, km.toggle_preview.desc),
    fmt("- **%s**: %s", km.toggle_fullscreen.key, km.toggle_fullscreen.desc),
    fmt("- **%s**: %s", km.toggle_word_diff.key, km.toggle_word_diff.desc),
    "",
    "## Navigation",
    fmt("- **%s** / **%s**: Next/Prev file", km.next_file_alt.key, km.prev_file_alt.key),
    fmt("- **%s** / **%s**: Next/Prev hunk", km.next_hunk.key, km.prev_hunk.key),
    fmt("- **%s** / **%s**: Next/Prev file (preview)", km.next_file.key, km.prev_file.key),
    fmt("- **%s**: %s (files window)", km.goto_file.key, km.goto_file.desc),
    fmt("- **%s** / **%s**: %s (preview)", km.goto_hunk.key, km.goto_hunk_alt.key, km.goto_hunk.desc),
    "",
    "## Actions",
    fmt("- **%s**: %s", km.revert_hunk.key, km.revert_hunk.desc),
    "",
    "## Checkpoints",
    fmt("- **%s**: %s (safe - shows cycle changes)", km.view_checkpoint.key, km.view_checkpoint.desc),
    fmt("- **%s**: %s (safe - shows accumulated to cycle)", km.view_cumulative.key, km.view_cumulative.desc),
    fmt("- **%s**: Reset checkpoint filter (safe - resets UI only)", km.reset_filter.key),
    fmt("- **%s**: %s", km.revert_checkpoint.key, km.revert_checkpoint.desc),
    fmt("- **%s**: %s", km.revert_all.key, km.revert_all.desc),
  }
end

---Toggle help window
---@param state FSMonitor.Diff.State
function M.toggle_help(state)
  local cfg = get_config()
  if state.help_win and api.nvim_win_is_valid(state.help_win) then
    pcall(api.nvim_win_close, state.help_win, true)
    if state.help_buf and api.nvim_buf_is_valid(state.help_buf) then
      pcall(api.nvim_buf_delete, state.help_buf, { force = true })
    end
    state.help_win = nil
    state.help_buf = nil
    return
  end

  local geom = state.get_geometry(state.is_fullscreen)

  state.help_buf = api.nvim_create_buf(false, true)
  set_option("buftype", "nofile", { buf = state.help_buf })
  set_option("bufhidden", "wipe", { buf = state.help_buf })
  set_option("filetype", "markdown", { buf = state.help_buf })

  local lines = generate_help_lines()
  api.nvim_buf_set_lines(state.help_buf, 0, -1, false, lines)

  state.help_win = api.nvim_open_win(state.help_buf, true, {
    relative = "editor",
    row = geom.row,
    col = geom.left_col,
    width = geom.left_w,
    height = geom.height,
    style = "minimal",
    border = "rounded",
    zindex = cfg.help_zindex,
    title = " 󰋖 Help ",
    title_pos = "center",
  })

  vim.wo[state.help_win].wrap = true
  vim.wo[state.help_win].conceallevel = 2

  local close_keys = { cfg.keymaps.close.key, cfg.keymaps.close_alt.key, cfg.keymaps.toggle_help.key }
  for _, key in ipairs(close_keys) do
    vim.keymap.set("n", key, function()
      M.toggle_help(state)
    end, {
      buffer = state.help_buf,
      noremap = true,
      silent = true,
      nowait = true,
    })
  end
end

---Toggle preview-only mode
---@param state FSMonitor.Diff.State
function M.toggle_preview_only(state)
  local g = state.get_geometry(state.is_fullscreen)

  if state.is_preview_only then
    update_win_config(state.files_win, {
      relative = "editor",
      row = g.row,
      col = g.left_col,
      width = g.left_w,
      height = g.files_h,
      hide = false,
    })
    update_win_config(state.checkpoints_win, {
      relative = "editor",
      row = g.checkpoints_row,
      col = g.left_col,
      width = g.left_w,
      height = g.checkpoints_h,
      hide = false,
    })
    update_win_config(state.right_win, {
      relative = "editor",
      row = g.row,
      col = g.right_col,
      width = g.right_w,
      height = g.height,
    })
    state.is_preview_only = false
  else
    local total_width = g.left_w + g.gap + g.right_w
    if state.is_fullscreen then total_width = vim.o.columns - 2 end

    update_win_config(state.files_win, { hide = true })
    update_win_config(state.checkpoints_win, { hide = true })
    update_win_config(state.right_win, {
      relative = "editor",
      row = g.row,
      col = state.is_fullscreen and 0 or g.left_col,
      width = total_width,
      height = g.height,
    })
    if api.nvim_win_is_valid(state.right_win) then api.nvim_set_current_win(state.right_win) end
    state.is_preview_only = true
  end
end

---Toggle fullscreen mode
---@param state FSMonitor.Diff.State
function M.toggle_fullscreen(state)
  state.is_fullscreen = not state.is_fullscreen
  local g = state.get_geometry(state.is_fullscreen)

  if state.is_preview_only then
    local total_width = g.left_w + g.gap + g.right_w
    if state.is_fullscreen then total_width = vim.o.columns - 2 end
    update_win_config(state.right_win, {
      relative = "editor",
      row = g.row,
      col = state.is_fullscreen and 0 or g.left_col,
      width = total_width,
      height = g.height,
    })
  else
    update_win_config(state.files_win, {
      relative = "editor",
      row = g.row,
      col = g.left_col,
      width = g.left_w,
      height = g.files_h,
    })
    update_win_config(state.checkpoints_win, {
      relative = "editor",
      row = g.checkpoints_row,
      col = g.left_col,
      width = g.left_w,
      height = g.checkpoints_h,
    })
    update_win_config(state.right_win, {
      relative = "editor",
      row = g.row,
      col = g.right_col,
      width = g.right_w,
      height = g.height,
    })
  end
end

---Toggle word-level diff highlighting
---@param state FSMonitor.Diff.State
function M.toggle_word_diff(state)
  local util = require("fs-monitor.utils.util")
  local navigation = require("fs-monitor.viewer.navigation")

  state.word_diff = not state.word_diff

  if state.selected_file_idx and #state.summary.files > 0 then navigation.update_preview(state, state.selected_file_idx) end

  local status = state.word_diff and "enabled" or "disabled"
  util.notify(fmt("Word diff %s", status), vim.log.levels.INFO)
end

---Create all buffers for the viewer
---@return table buffers {files_buf, checkpoints_buf, right_buf}
function M.create_buffers()
  local files_buf = api.nvim_create_buf(false, true)
  set_option("buftype", "nofile", { buf = files_buf })
  set_option("bufhidden", "wipe", { buf = files_buf })
  set_option("filetype", "fs-monitor-viewer-files", { buf = files_buf })

  local checkpoints_buf = api.nvim_create_buf(false, true)
  set_option("buftype", "nofile", { buf = checkpoints_buf })
  set_option("bufhidden", "wipe", { buf = checkpoints_buf })
  set_option("filetype", "fs-monitor-viewer-checkpoints", { buf = checkpoints_buf })

  local right_buf = api.nvim_create_buf(false, true)
  set_option("buftype", "nofile", { buf = right_buf })
  set_option("bufhidden", "wipe", { buf = right_buf })
  set_option("modifiable", false, { buf = right_buf })
  api.nvim_buf_set_name(right_buf, "fs-monitor-viewer")

  return {
    files_buf = files_buf,
    checkpoints_buf = checkpoints_buf,
    right_buf = right_buf,
  }
end

---Create all windows for the viewer
---@param buffers table Created buffers
---@param geom table Window geometry
---@return table windows {files_win, checkpoints_win, right_win}
function M.create_windows(buffers, geom)
  local ui_utils = require("fs-monitor.utils.ui")
  local cfg = get_config()
  local km = cfg.keymaps

  local files_win = api.nvim_open_win(buffers.files_buf, true, {
    relative = "editor",
    row = geom.row,
    col = geom.left_col,
    width = geom.left_w,
    height = geom.files_h,
    style = "minimal",
    border = "rounded",
    zindex = cfg.zindex,
    title = cfg.titles.files,
    title_pos = "center",
  })

  local checkpoints_win = api.nvim_open_win(buffers.checkpoints_buf, false, {
    relative = "editor",
    row = geom.checkpoints_row,
    col = geom.left_col,
    width = geom.left_w,
    height = geom.checkpoints_h,
    style = "minimal",
    border = "rounded",
    zindex = cfg.zindex,
    title = cfg.titles.checkpoints,
    title_pos = "center",
  })

  local right_win = api.nvim_open_win(buffers.right_buf, false, {
    relative = "editor",
    row = geom.row,
    col = geom.right_col,
    width = geom.right_w,
    height = geom.height,
    style = "minimal",
    border = "rounded",
    zindex = cfg.zindex,
    title = cfg.titles.preview,
    title_pos = "center",
  })

  local win_opts = { number = false, relativenumber = false, wrap = false, cursorline = true, winfixbuf = true }
  for opt, val in pairs(win_opts) do
    vim.wo[files_win][opt] = val
    vim.wo[checkpoints_win][opt] = val
  end
  vim.wo[right_win].number = false
  vim.wo[right_win].relativenumber = false
  vim.wo[right_win].wrap = false
  vim.wo[right_win].cursorline = false
  vim.wo[right_win].scrollbind = false
  vim.wo[right_win].winfixbuf = true

  ui_utils.set_winbar(files_win, {
    { keys = km.cycle_focus.key, desc = "Tab" },
    { keys = km.goto_file.key, desc = "File" },
    { keys = km.toggle_help.key, desc = "Help" },
  })

  ui_utils.set_winbar(checkpoints_win, {
    { keys = km.view_checkpoint.key, desc = "View" },
    { keys = km.view_cumulative.key, desc = "Accum" },
    { keys = km.revert_checkpoint.key, desc = "Revert" },
  })

  ui_utils.set_winbar(right_win, {
    { keys = km.toggle_preview.key, desc = km.toggle_preview.desc },
    { keys = km.toggle_fullscreen.key, desc = km.toggle_fullscreen.desc },
    { keys = km.toggle_word_diff.key, desc = "Diff-Word" },
    { keys = km.revert_hunk.key, desc = "Revert" },
    { keys = km.next_hunk.key .. "/" .. km.prev_hunk.key, desc = "Hunk" },
    { keys = km.next_file.key .. "/" .. km.prev_file.key, desc = "Nav" },
    { keys = km.toggle_help.key, desc = "Help" },
  })

  return {
    files_win = files_win,
    checkpoints_win = checkpoints_win,
    right_win = right_win,
  }
end

---Set a keymap on a buffer
---@param buf number
---@param key string
---@param callback function
---@param desc string
local function set_keymap(buf, key, callback, desc)
  vim.keymap.set("n", key, callback, {
    buffer = buf,
    noremap = true,
    silent = true,
    nowait = true,
    desc = desc,
  })
end

---Setup keymaps for all buffers
---@param state FSMonitor.Diff.State
function M.setup_keymaps(state)
  local cfg = get_config()
  local km = cfg.keymaps
  local navigation = require("fs-monitor.viewer.navigation")
  local operations = require("fs-monitor.viewer.operations")

  local common_maps = {
    { km.close.key, function() M.close_windows(state) end, km.close.desc },
    { km.close_alt.key, function() M.close_windows(state) end, km.close_alt.desc },
    { km.toggle_help.key, function() M.toggle_help(state) end, km.toggle_help.desc },
    { km.toggle_preview.key, function() M.toggle_preview_only(state) end, km.toggle_preview.desc },
    { km.toggle_fullscreen.key, function() M.toggle_fullscreen(state) end, km.toggle_fullscreen.desc },
    { km.toggle_word_diff.key, function() M.toggle_word_diff(state) end, km.toggle_word_diff.desc },
  }

  for _, map in ipairs(common_maps) do
    set_keymap(state.files_buf, map[1], map[2], map[3])
    set_keymap(state.checkpoints_buf, map[1], map[2], map[3])
  end

  local files_maps = {
    { km.next_file.key, function() navigation.navigate_files(state, 1) end, km.next_file.desc },
    { km.prev_file.key, function() navigation.navigate_files(state, -1) end, km.prev_file.desc },
    { km.next_file_alt.key, function() navigation.navigate_files(state, 1) end, km.next_file_alt.desc },
    { km.prev_file_alt.key, function() navigation.navigate_files(state, -1) end, km.prev_file_alt.desc },
    { km.goto_file.key, function() navigation.goto_file_in_editor(state, M.close_windows) end, km.goto_file.desc },
    {
      km.cycle_focus.key,
      function()
        local current = api.nvim_get_current_win()
        if current == state.files_win then
          api.nvim_set_current_win(state.checkpoints_win)
        elseif current == state.checkpoints_win then
          api.nvim_set_current_win(state.right_win)
        else
          api.nvim_set_current_win(state.files_win)
        end
      end,
      km.cycle_focus.desc,
    },
  }

  for _, map in ipairs(files_maps) do
    set_keymap(state.files_buf, map[1], map[2], map[3])
  end

  local checkpoint_maps = {
    { km.reset_filter.key, function() navigation.reset_checkpoint_filter(state, M.refresh_ui) end, km.reset_filter.desc },
    { km.revert_all.key, function() operations.revert_to_original(state, M.close_windows) end, km.revert_all.desc },
    { km.cycle_focus.key, function() api.nvim_set_current_win(state.right_win) end, km.cycle_focus.desc },
    {
      km.view_checkpoint.key,
      function()
        if #state.checkpoints == 0 then return end
        local cursor = api.nvim_win_get_cursor(state.checkpoints_win)
        local idx = cursor[1]
        if idx >= 1 and idx <= #state.checkpoints then
          navigation.apply_checkpoint_filter(state, idx, "differential", M.refresh_ui)
        end
      end,
      km.view_checkpoint.desc,
    },
    {
      km.view_cumulative.key,
      function()
        if #state.checkpoints == 0 then return end
        local cursor = api.nvim_win_get_cursor(state.checkpoints_win)
        local idx = cursor[1]
        if idx >= 1 and idx <= #state.checkpoints then
          navigation.apply_checkpoint_filter(state, idx, "cumulative", M.refresh_ui)
        end
      end,
      km.view_cumulative.desc,
    },
    {
      km.revert_checkpoint.key,
      function()
        if #state.checkpoints == 0 then return end
        local cursor = api.nvim_win_get_cursor(state.checkpoints_win)
        local idx = cursor[1]
        if idx >= 1 and idx <= #state.checkpoints then
          operations.revert_to_checkpoint(state, idx, M.refresh_ui)
        end
      end,
      km.revert_checkpoint.desc,
    },
  }

  for _, map in ipairs(checkpoint_maps) do
    set_keymap(state.checkpoints_buf, map[1], map[2], map[3])
  end

  state.right_keymaps = {
    { key = km.close.key, callback = function() M.close_windows(state) end, desc = km.close.desc },
    { key = km.close_alt.key, callback = function() M.close_windows(state) end, desc = km.close_alt.desc },
    { key = km.toggle_help.key, callback = function() M.toggle_help(state) end, desc = km.toggle_help.desc },
    { key = km.toggle_preview.key, callback = function() M.toggle_preview_only(state) end, desc = km.toggle_preview.desc },
    { key = km.toggle_fullscreen.key, callback = function() M.toggle_fullscreen(state) end, desc = km.toggle_fullscreen.desc },
    { key = km.cycle_focus.key, callback = function() api.nvim_set_current_win(state.files_win) end, desc = km.cycle_focus.desc },
    { key = km.next_file.key, callback = function() navigation.navigate_files(state, 1) end, desc = km.next_file.desc },
    { key = km.prev_file.key, callback = function() navigation.navigate_files(state, -1) end, desc = km.prev_file.desc },
    { key = km.goto_hunk.key, callback = function() navigation.jump_to_file_line(state, M.close_windows) end, desc = km.goto_hunk.desc },
    { key = km.goto_hunk_alt.key, callback = function() navigation.jump_to_file_line(state, M.close_windows) end, desc = km.goto_hunk_alt.desc },
    { key = km.next_hunk.key, callback = function() navigation.jump_next_hunk(state) end, desc = km.next_hunk.desc },
    { key = km.prev_hunk.key, callback = function() navigation.jump_prev_hunk(state) end, desc = km.prev_hunk.desc },
    { key = km.toggle_word_diff.key, callback = function() M.toggle_word_diff(state) end, desc = km.toggle_word_diff.desc },
    { key = km.revert_hunk.key, callback = function() operations.revert_current_hunk(state, M.refresh_ui) end, desc = km.revert_hunk.desc },
  }

  for _, keymap in ipairs(state.right_keymaps) do
    set_keymap(state.right_buf, keymap.key, keymap.callback, keymap.desc)
  end
end

---Setup autocmds for the viewer
---@param state FSMonitor.Diff.State
function M.setup_autocmds(state)
  local render = require("fs-monitor.viewer.render")
  local navigation = require("fs-monitor.viewer.navigation")

  state.aug = api.nvim_create_augroup("FSMonitorViewer", { clear = true })

  api.nvim_create_autocmd({ "CursorMoved" }, {
    group = state.aug,
    buffer = state.files_buf,
    callback = function()
      if not api.nvim_win_is_valid(state.files_win) then return end
      local cursor = api.nvim_win_get_cursor(state.files_win)
      local line = cursor[1]
      if line > 0 and line <= #state.summary.files then
        state.selected_file_idx = line
        navigation.update_preview(state, line)
        set_option("modifiable", true, { buf = state.files_buf })
        render.new(state.files_buf, state.ns):render_file_list(state.summary.files, state.summary.by_file, line)
        set_option("modifiable", false, { buf = state.files_buf })
      end
    end,
  })

  api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = state.aug,
    buffer = state.files_buf,
    callback = function()
      M.close_windows(state)
    end,
  })

  api.nvim_create_autocmd({ "WinClosed" }, {
    group = state.aug,
    callback = function()
      local all_valid = api.nvim_win_is_valid(state.files_win)
        and api.nvim_win_is_valid(state.checkpoints_win)
        and api.nvim_win_is_valid(state.right_win)
      if not all_valid then M.close_windows(state) end
    end,
  })

  api.nvim_create_autocmd({ "VimResized" }, {
    group = state.aug,
    callback = function()
      local g = state.get_geometry(state.is_fullscreen)
      update_win_config(state.files_win, {
        relative = "editor",
        row = g.row,
        col = g.left_col,
        width = g.left_w,
        height = g.files_h,
      })
      update_win_config(state.checkpoints_win, {
        relative = "editor",
        row = g.checkpoints_row,
        col = g.left_col,
        width = g.left_w,
        height = g.checkpoints_h,
      })
      update_win_config(state.right_win, {
        relative = "editor",
        row = g.row,
        col = g.right_col,
        width = g.right_w,
        height = g.height,
      })
    end,
  })
end

return M
