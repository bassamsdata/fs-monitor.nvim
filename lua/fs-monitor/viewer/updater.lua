---@module "fs-monitor.types"

---Internal module for updating viewer UI
---@class FSMonitor.Viewer.Updater
local M = {}

local api = vim.api
local set_option = vim.api.nvim_set_option_value
local fmt = string.format

---Update preview for selected file
---@param viewer FSMonitor.Viewer
function M.update_preview(viewer)
  local render = require("fs-monitor.viewer.render")
  local hunk_calculator = require("fs-monitor.viewer.hunk_calculator")
  local util = require("fs-monitor.utils.util")
  local builder = require("fs-monitor.viewer.builder")
  local cfg = viewer:get_config()

  local filepath = viewer.summary.files[viewer.selected_file_idx]
  if not filepath then return end

  local file_info = viewer.summary.by_file[filepath]
  if not file_info or #file_info.changes == 0 then return end

  local cached = viewer:get_cached_preview(filepath)
  if cached then
    set_option("modifiable", true, { buf = viewer.right_buf })
    api.nvim_buf_set_lines(viewer.right_buf, 0, -1, false, cached.lines)
    api.nvim_buf_clear_namespace(viewer.right_buf, viewer.ns, 0, -1)

    for _, hl in ipairs(cached.highlights) do
      local opts = {
        end_row = hl.end_row,
        end_col = hl.col_end,
        hl_group = hl.group,
        hl_eol = hl.hl_eol,
        priority = hl.priority,
        virt_text = hl.virt_text,
        virt_text_pos = hl.virt_text_pos,
        sign_text = hl.sign_text,
        sign_hl_group = hl.sign_hl_group,
        hl_mode = hl.hl_mode,
      }
      pcall(api.nvim_buf_set_extmark, viewer.right_buf, viewer.ns, hl.line, hl.col_start, opts)
    end

    set_option("modifiable", false, { buf = viewer.right_buf })

    viewer.line_mappings = cached.line_mappings
    viewer.current_filepath = filepath
    viewer.hunks = cached.hunks
    viewer.hunk_ranges = cached.hunk_ranges

    if cached.filetype and cached.filetype ~= "" then
      set_option("filetype", cached.filetype, { buf = viewer.right_buf })
      builder.reapply_right_keymaps(viewer)
    end

    if api.nvim_win_is_valid(viewer.right_win) then
      api.nvim_win_set_config(viewer.right_win, {
        title = cached.title,
        title_pos = "center",
      })
    end

    return
  end

  local first_change = file_info.changes[1]
  local last_change = file_info.changes[#file_info.changes]
  local net_operation = file_info.net_operation

  local old_lines = {}
  local new_lines = {}

  if net_operation == "created" then
    old_lines = {}
    if last_change.new_content then
      new_lines = vim.split(last_change.new_content, "\n", { plain = true })
    else
      new_lines = { "(empty file)" }
    end
  elseif net_operation == "deleted" or net_operation == "transient" then
    if first_change.old_content then
      old_lines = vim.split(first_change.old_content, "\n", { plain = true })
    else
      old_lines = { "(empty file)" }
    end
    new_lines = {}
  else
    if first_change.old_content then old_lines = vim.split(first_change.old_content, "\n", { plain = true }) end
    if last_change.new_content then new_lines = vim.split(last_change.new_content, "\n", { plain = true }) end
  end

  local hunks = hunk_calculator.calculate_hunks(old_lines, new_lines, 3)
  local ft = vim.filetype.match({ filename = filepath }) or ""

  set_option("modifiable", true, { buf = viewer.right_buf })
  api.nvim_buf_clear_namespace(viewer.right_buf, viewer.ns, 0, -1)
  local lines, line_mappings, hunk_ranges = render.new(viewer.right_buf, viewer.ns):render_diff(hunks, viewer.word_diff)
  set_option("modifiable", false, { buf = viewer.right_buf })

  viewer.line_mappings = line_mappings
  viewer.current_filepath = filepath
  viewer.hunks = hunks
  viewer.hunk_ranges = hunk_ranges

  if ft and ft ~= "" then
    set_option("filetype", ft, { buf = viewer.right_buf })
    builder.reapply_right_keymaps(viewer)
  end

  local title_icon = cfg.icons.modified
  if net_operation == "created" then
    title_icon = cfg.icons.created
  elseif net_operation == "deleted" then
    title_icon = cfg.icons.deleted
  elseif net_operation == "renamed" then
    title_icon = cfg.icons.renamed
  elseif net_operation == "transient" then
    title_icon = cfg.icons.transient
  end
  local title_name = vim.fn.fnamemodify(filepath, ":t")
  if net_operation == "renamed" and file_info.old_path then
    local old_name = vim.fn.fnamemodify(file_info.old_path, ":t")
    title_name = old_name .. " → " .. title_name
  end

  local hunk_count_str = ""
  if #hunks > 0 then hunk_count_str = fmt(" [%d %s]", #hunks, util.pluralize(#hunks, "hunk")) end

  local title = fmt(" %s %s%s ", title_icon, title_name, hunk_count_str)

  if api.nvim_win_is_valid(viewer.right_win) then
    api.nvim_win_set_config(viewer.right_win, {
      title = title,
      title_pos = "center",
    })
  end

  local buffer_lines = api.nvim_buf_get_lines(viewer.right_buf, 0, -1, false)
  local highlights = {}
  local extmarks = api.nvim_buf_get_extmarks(viewer.right_buf, viewer.ns, 0, -1, { details = true })
  for _, extmark in ipairs(extmarks) do
    local mark_line = extmark[2]
    local mark_col = extmark[3]
    local details = extmark[4]
    if details and details.hl_group then
      table.insert(highlights, {
        line = mark_line,
        col_start = mark_col,
        col_end = details.end_col or -1,
        group = details.hl_group,
        end_row = details.end_row,
        hl_eol = details.hl_eol,
        priority = details.priority,
        virt_text = details.virt_text,
        virt_text_pos = details.virt_text_pos,
        sign_text = details.sign_text,
        sign_hl_group = details.sign_hl_group,
        hl_mode = details.hl_mode,
      })
    end
  end

  viewer:set_cached_preview(filepath, {
    lines = buffer_lines,
    highlights = highlights,
    line_mappings = line_mappings,
    hunks = hunks,
    hunk_ranges = hunk_ranges,
    filetype = ft,
    title = title,
  })
end

---Refresh all UI panels
---@param viewer FSMonitor.Viewer
---@param opts? { selected_checkpoint_idx?: number|nil, show_empty_message?: boolean }
function M.refresh_ui(viewer, opts)
  opts = opts or {}
  local render = require("fs-monitor.viewer.render")

  set_option("modifiable", true, { buf = viewer.files_buf })
  render
    .new(viewer.files_buf, viewer.ns)
    :render_file_list(viewer.summary.files, viewer.summary.by_file, viewer.selected_file_idx)
  set_option("modifiable", false, { buf = viewer.files_buf })

  set_option("modifiable", true, { buf = viewer.checkpoints_buf })
  render
    .new(viewer.checkpoints_buf, viewer.ns)
    :render_checkpoints(viewer.checkpoints, viewer.all_changes, opts.selected_checkpoint_idx)
  set_option("modifiable", false, { buf = viewer.checkpoints_buf })

  if #viewer.summary.files > 0 then
    if viewer.selected_file_idx > #viewer.summary.files then viewer.selected_file_idx = #viewer.summary.files end
    if viewer.selected_file_idx < 1 then viewer.selected_file_idx = 1 end
    pcall(api.nvim_win_set_cursor, viewer.files_win, { viewer.selected_file_idx, 0 })
    M.update_preview(viewer)
  elseif opts.show_empty_message then
    set_option("modifiable", true, { buf = viewer.right_buf })
    api.nvim_buf_set_lines(viewer.right_buf, 0, -1, false, { "", "No changes remaining", "" })
    set_option("modifiable", false, { buf = viewer.right_buf })
  end
end

return M
