---@module "fs-monitor.types"

---Internal module for building viewer UI components
---@class FSMonitor.Viewer.Builder
local M = {}

local api = vim.api
local set_option = vim.api.nvim_set_option_value

---Create all buffers for the viewer
---@param viewer FSMonitor.Viewer
function M.create_buffers(viewer)
  viewer.files_buf = api.nvim_create_buf(false, true)
  set_option("buftype", "nofile", { buf = viewer.files_buf })
  set_option("bufhidden", "wipe", { buf = viewer.files_buf })
  set_option("filetype", "fs-monitor-viewer-files", { buf = viewer.files_buf })

  viewer.checkpoints_buf = api.nvim_create_buf(false, true)
  set_option("buftype", "nofile", { buf = viewer.checkpoints_buf })
  set_option("bufhidden", "wipe", { buf = viewer.checkpoints_buf })
  set_option("filetype", "fs-monitor-viewer-checkpoints", { buf = viewer.checkpoints_buf })

  viewer.right_buf = api.nvim_create_buf(false, true)
  set_option("buftype", "nofile", { buf = viewer.right_buf })
  set_option("bufhidden", "wipe", { buf = viewer.right_buf })
  set_option("modifiable", false, { buf = viewer.right_buf })
  api.nvim_buf_set_name(viewer.right_buf, "fs-monitor-viewer")
end

---Create all windows for the viewer
---@param viewer FSMonitor.Viewer
---@param geom table Window geometry
---@param cfg FSMonitor.DiffConfig Configuration
function M.create_windows(viewer, geom, cfg)
  local ui_utils = require("fs-monitor.utils.ui")
  local km = cfg.keymaps

  viewer.files_win = api.nvim_open_win(viewer.files_buf, true, {
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

  viewer.checkpoints_win = api.nvim_open_win(viewer.checkpoints_buf, false, {
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

  viewer.right_win = api.nvim_open_win(viewer.right_buf, false, {
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
    vim.wo[viewer.files_win][opt] = val
    vim.wo[viewer.checkpoints_win][opt] = val
    vim.wo[viewer.right_win][opt] = val
  end
  vim.wo[viewer.right_win].cursorline = false
  vim.wo[viewer.right_win].scrollbind = false
  vim.b[viewer.right_buf].miniindentscope_disable = true

  ui_utils.set_winbar(viewer.files_win, {
    { keys = km.cycle_focus.key, desc = "Tab" },
    { keys = km.goto_file.key, desc = "File" },
    { keys = km.toggle_help.key, desc = "Help" },
  })

  ui_utils.set_winbar(viewer.checkpoints_win, {
    { keys = km.view_checkpoint.key, desc = "View" },
    { keys = km.view_cumulative.key, desc = "Accum" },
    { keys = km.revert_checkpoint.key, desc = "Revert" },
  })

  ui_utils.set_winbar(viewer.right_win, {
    { keys = km.toggle_preview.key, desc = km.toggle_preview.desc },
    { keys = km.toggle_fullscreen.key, desc = km.toggle_fullscreen.desc },
    { keys = km.toggle_word_diff.key, desc = "Diff-Word" },
    { keys = km.revert_hunk.key, desc = "Revert" },
    { keys = km.next_hunk.key .. "/" .. km.prev_hunk.key, desc = "Hunk" },
    { keys = km.next_file.key .. "/" .. km.prev_file.key, desc = "Nav" },
    { keys = km.toggle_help.key, desc = "Help" },
  })
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
---@param viewer FSMonitor.Viewer
---@param cfg FSMonitor.DiffConfig
function M.setup_keymaps(viewer, cfg)
  local km = cfg.keymaps

  local common_maps = {
    -- stylua: ignore start
    { km.close.key, function() viewer:close() end, km.close.desc },
    { km.close_alt.key, function() viewer:close() end, km.close_alt.desc },
    { km.toggle_help.key, function() viewer:toggle_help() end, km.toggle_help.desc },
    { km.toggle_preview.key, function() viewer:toggle_preview_only() end, km.toggle_preview.desc },
    { km.toggle_fullscreen.key, function() viewer:toggle_fullscreen() end, km.toggle_fullscreen.desc },
    { km.toggle_word_diff.key, function() viewer:toggle_word_diff() end, km.toggle_word_diff.desc },
    -- stylua: ignore end
  }

  for _, map in ipairs(common_maps) do
    set_keymap(viewer.files_buf, map[1], map[2], map[3])
    set_keymap(viewer.checkpoints_buf, map[1], map[2], map[3])
  end

  local files_maps = {
    -- stylua: ignore start
    { km.next_file.key, function() viewer:next_file() end, km.next_file.desc },
    { km.prev_file.key, function() viewer:prev_file() end, km.prev_file.desc },
    { km.next_file_alt.key, function() viewer:next_file() end, km.next_file_alt.desc },
    { km.prev_file_alt.key, function() viewer:prev_file() end, km.prev_file_alt.desc },
    { km.goto_file.key, function() viewer:goto_file_in_editor() end, km.goto_file.desc },
    {
      km.cycle_focus.key,
      function()
        local current = api.nvim_get_current_win()
        if current == viewer.files_win then
          api.nvim_set_current_win(viewer.right_win)
        elseif current == viewer.right_win then
          api.nvim_set_current_win(viewer.checkpoints_win)
        elseif current == viewer.checkpoints_win then
          api.nvim_set_current_win(viewer.files_win)
        else
          api.nvim_set_current_win(viewer.files_win)
        end
      end,
      km.cycle_focus.desc,
    },
  }
  -- stylua: ignore end

  for _, map in ipairs(files_maps) do
    set_keymap(viewer.files_buf, map[1], map[2], map[3])
  end

  local checkpoint_maps = {
    -- stylua: ignore start
    { km.reset_filter.key, function() viewer:reset_checkpoint_filter() end, km.reset_filter.desc },
    { km.revert_all.key, function() viewer:revert_to_original() end, km.revert_all.desc },
    { km.cycle_focus.key, function() api.nvim_set_current_win(viewer.files_win) end, km.cycle_focus.desc },
    {
      km.view_checkpoint.key,
      function()
        if #viewer.checkpoints == 0 then return end
        local cursor = api.nvim_win_get_cursor(viewer.checkpoints_win)
        local idx = cursor[1]
        if idx >= 1 and idx <= #viewer.checkpoints then viewer:apply_checkpoint_filter(idx, "differential") end
      end,
      km.view_checkpoint.desc,
    },
    {
      km.view_cumulative.key,
      function()
        if #viewer.checkpoints == 0 then return end
        local cursor = api.nvim_win_get_cursor(viewer.checkpoints_win)
        local idx = cursor[1]
        if idx >= 1 and idx <= #viewer.checkpoints then viewer:apply_checkpoint_filter(idx, "cumulative") end
      end,
      km.view_cumulative.desc,
    },
    {
      km.revert_checkpoint.key,
      function()
        if #viewer.checkpoints == 0 then return end
        local cursor = api.nvim_win_get_cursor(viewer.checkpoints_win)
        local idx = cursor[1]
        if idx >= 1 and idx <= #viewer.checkpoints then viewer:revert_to_checkpoint(idx) end
      end,
      km.revert_checkpoint.desc,
    },
    -- stylua: ignore end
  }

  for _, map in ipairs(checkpoint_maps) do
    set_keymap(viewer.checkpoints_buf, map[1], map[2], map[3])
  end

  viewer.right_keymaps = {
    -- stylua: ignore start
    { key = km.close.key, callback = function() viewer:close() end, desc = km.close.desc },
    { key = km.close_alt.key, callback = function() viewer:close() end, desc = km.close_alt.desc },
    { key = km.toggle_help.key, callback = function() viewer:toggle_help() end, desc = km.toggle_help.desc },
    { key = km.toggle_preview.key, callback = function() viewer:toggle_preview_only() end, desc = km.toggle_preview.desc },
    { key = km.toggle_fullscreen.key, callback = function() viewer:toggle_fullscreen() end, desc = km.toggle_fullscreen.desc },
    { key = km.cycle_focus.key, callback = function() api.nvim_set_current_win(viewer.checkpoints_win) end, desc = km.cycle_focus.desc },
    { key = km.next_file.key, callback = function() viewer:next_file() end, desc = km.next_file.desc },
    { key = km.prev_file.key, callback = function() viewer:prev_file() end, desc = km.prev_file.desc },
    { key = km.goto_hunk.key, callback = function() viewer:jump_to_file_line() end, desc = km.goto_hunk.desc },
    { key = km.goto_hunk_alt.key, callback = function() viewer:jump_to_file_line() end, desc = km.goto_hunk_alt.desc },
    { key = km.next_hunk.key, callback = function() viewer:next_hunk() end, desc = km.next_hunk.desc },
    { key = km.prev_hunk.key, callback = function() viewer:prev_hunk() end, desc = km.prev_hunk.desc },
    { key = km.toggle_word_diff.key, callback = function() viewer:toggle_word_diff() end, desc = km.toggle_word_diff.desc },
    { key = km.revert_hunk.key, callback = function() viewer:revert_current_hunk() end, desc = km.revert_hunk.desc },
    -- stylua: ignore end
  }

  for _, keymap in ipairs(viewer.right_keymaps) do
    set_keymap(viewer.right_buf, keymap.key, keymap.callback, keymap.desc)
  end
end

---Reapply keymaps to right buffer (needed after filetype changes)
---@param viewer FSMonitor.Viewer
function M.reapply_right_keymaps(viewer)
  if not viewer.right_keymaps or not api.nvim_buf_is_valid(viewer.right_buf) then return end

  for _, keymap in ipairs(viewer.right_keymaps) do
    vim.keymap.set("n", keymap.key, keymap.callback, {
      buffer = viewer.right_buf,
      noremap = true,
      silent = true,
      nowait = true,
      desc = keymap.desc,
    })
  end
end

---Setup autocmds for the viewer
---@param viewer FSMonitor.Viewer
function M.setup_autocmds(viewer)
  local render = require("fs-monitor.viewer.render")

  viewer.aug = api.nvim_create_augroup("FSMonitorViewer", { clear = true })

  api.nvim_create_autocmd({ "CursorMoved" }, {
    group = viewer.aug,
    buffer = viewer.files_buf,
    callback = function()
      if not api.nvim_win_is_valid(viewer.files_win) then return end
      local cursor = api.nvim_win_get_cursor(viewer.files_win)
      local line = cursor[1]
      if line > 0 and line <= #viewer.summary.files then
        viewer.selected_file_idx = line
        viewer:_update_preview()
        set_option("modifiable", true, { buf = viewer.files_buf })
        render.new(viewer.files_buf, viewer.ns):render_file_list(viewer.summary.files, viewer.summary.by_file, line)
        set_option("modifiable", false, { buf = viewer.files_buf })
      end
    end,
  })

  api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = viewer.aug,
    buffer = viewer.files_buf,
    callback = function()
      viewer:close()
    end,
  })

  api.nvim_create_autocmd({ "WinClosed" }, {
    group = viewer.aug,
    callback = function()
      local all_valid = api.nvim_win_is_valid(viewer.files_win)
        and api.nvim_win_is_valid(viewer.checkpoints_win)
        and api.nvim_win_is_valid(viewer.right_win)
      if not all_valid then viewer:close() end
    end,
  })

  api.nvim_create_autocmd({ "VimResized" }, {
    group = viewer.aug,
    callback = function()
      local g = viewer:get_geometry()
      viewer:_update_win_config(viewer.files_win, {
        relative = "editor",
        row = g.row,
        col = g.left_col,
        width = g.left_w,
        height = g.files_h,
      })
      viewer:_update_win_config(viewer.checkpoints_win, {
        relative = "editor",
        row = g.checkpoints_row,
        col = g.left_col,
        width = g.left_w,
        height = g.checkpoints_h,
      })
      viewer:_update_win_config(viewer.right_win, {
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
