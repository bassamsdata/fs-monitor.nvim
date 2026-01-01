---@class FSMonitor.Diff.Render
local M = {}

local api = vim.api

---Get diff configuration
---@return FSMonitor.DiffConfig
local function get_config()
  return require("fs-monitor.config").diff_options
end

---Apply extmarks to buffer
---@param buf number
---@param ns number
---@param extmarks table[]
function M.apply_extmarks(buf, ns, extmarks)
  for _, mark in ipairs(extmarks) do
    pcall(api.nvim_buf_set_extmark, buf, ns, mark.line, mark.col, mark.opts)
  end
end

---Pad empty lines to prevent cursor jumping to column 0
---@param line string
---@return string
function M.pad(line)
  return line == "" and " " or line
end

---Format diff lines with extmarks for line numbers, highlights, and signs
---@param buf number
---@param ns number
---@param hunks FSMonitor.Diff.Hunk[]
---@return number line_count
---@return table line_mappings Table mapping diff buffer line (0-indexed) to file line info
---@return table hunk_ranges Array of {start_line, end_line} for each hunk (1-indexed)
function M.render_diff(buf, ns, hunks)
  local cfg = get_config()
  local lines = {}
  local extmarks = {}
  local line_mappings = {}
  local hunk_ranges = {}
  local sign_text = cfg.icons.sign

  for hunk_idx, hunk in ipairs(hunks) do
    local hunk_start = #lines + 1

    local header = string.format(
      "@@ -%d,%d +%d,%d @@",
      hunk.original_start,
      hunk.original_count,
      hunk.updated_start,
      hunk.updated_count
    )
    table.insert(lines, header)
    table.insert(extmarks, {
      line = #lines - 1,
      col = 0,
      opts = {
        end_line = #lines,
        hl_group = "FSMonitorHeader",
      },
    })

    for idx, ctx_line in ipairs(hunk.context_before) do
      local line_nr = hunk.original_start - #hunk.context_before + idx - 1
      table.insert(lines, M.pad(ctx_line))
      line_mappings[#lines - 1] = { original_line = line_nr, updated_line = line_nr, type = "context" }
      local line_nr_text = string.format("%4d  %4d ", line_nr, line_nr)
      table.insert(extmarks, {
        line = #lines - 1,
        col = 0,
        opts = {
          line_hl_group = "FSMonitorContext",
          virt_text = { { line_nr_text, "FSMonitorContextLineNr" } },
          virt_text_pos = "inline",
          hl_mode = "replace",
          sign_text = sign_text,
          sign_hl_group = "FSMonitorContextLineNr",
        },
      })
    end

    local is_modified_hunk = #hunk.removed_lines > 0 and #hunk.added_lines > 0
    for idx, removed_line in ipairs(hunk.removed_lines) do
      local old_line_nr = hunk.original_start + idx - 1
      table.insert(lines, M.pad(removed_line))
      line_mappings[#lines - 1] = { original_line = old_line_nr, updated_line = nil, type = "removed" }
      local line_nr_text = string.format("%4d       ", old_line_nr)
      local sign_hl = is_modified_hunk and "FSMonitorChangeLineNr" or "FSMonitorDeleteLineNr"
      table.insert(extmarks, {
        line = #lines - 1,
        col = 0,
        opts = {
          line_hl_group = "FSMonitorDelete",
          virt_text = { { line_nr_text, "FSMonitorDeleteLineNr" } },
          virt_text_pos = "inline",
          sign_text = sign_text,
          sign_hl_group = sign_hl,
        },
      })
    end

    for idx, added_line in ipairs(hunk.added_lines) do
      local new_line_nr = hunk.updated_start + idx - 1
      table.insert(lines, M.pad(added_line))
      line_mappings[#lines - 1] = { original_line = nil, updated_line = new_line_nr, type = "added" }
      local line_nr_text = string.format("      %4d ", new_line_nr)
      local sign_hl = is_modified_hunk and "FSMonitorChangeLineNr" or "FSMonitorAddLineNr"
      table.insert(extmarks, {
        line = #lines - 1,
        col = 0,
        opts = {
          line_hl_group = "FSMonitorAdd",
          virt_text = { { line_nr_text, "FSMonitorAddLineNr" } },
          virt_text_pos = "inline",
          sign_text = sign_text,
          sign_hl_group = sign_hl,
        },
      })
    end

    for idx, ctx_line in ipairs(hunk.context_after) do
      local line_nr = hunk.original_start + hunk.original_count + idx - 1
      table.insert(lines, M.pad(ctx_line))
      line_mappings[#lines - 1] = { original_line = line_nr, updated_line = line_nr, type = "context" }
      local line_nr_text = string.format("%4d  %4d ", line_nr, line_nr)
      table.insert(extmarks, {
        line = #lines - 1,
        col = 0,
        opts = {
          line_hl_group = "FSMonitorContext",
          virt_text = { { line_nr_text, "FSMonitorContextLineNr" } },
          virt_text_pos = "inline",
          sign_text = sign_text,
          sign_hl_group = "FSMonitorContextLineNr",
        },
      })
    end

    local hunk_end = #lines
    table.insert(hunk_ranges, { start_line = hunk_start, end_line = hunk_end })

    if hunk_idx < #hunks then
      table.insert(lines, "")
      table.insert(lines, "")
    end
  end

  if #lines == 0 then
    table.insert(lines, "")
    table.insert(lines, "No differences detected")
    table.insert(lines, "")
  end

  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  M.apply_extmarks(buf, ns, extmarks)

  return #lines, line_mappings, hunk_ranges
end

---Render file list in files buffer (top left)
---@param buf number
---@param ns number
---@param files string[]
---@param by_file table
---@param selected_idx? number
function M.render_file_list(buf, ns, files, by_file, selected_idx)
  local cfg = get_config()
  local lines = {}
  local extmarks = {}

  for idx, filepath in ipairs(files) do
    local file_info = by_file[filepath]
    local icon = " "

    if file_info.net_operation == "created" then
      icon = cfg.icons.created
    elseif file_info.net_operation == "deleted" then
      icon = cfg.icons.deleted
    elseif file_info.net_operation == "modified" then
      icon = cfg.icons.modified
    elseif file_info.net_operation == "renamed" then
      icon = cfg.icons.renamed
    end

    local prefix = idx == selected_idx and cfg.icons.file_selector or "  "
    local name = vim.fn.fnamemodify(filepath, ":t")
    local dir = vim.fn.fnamemodify(filepath, ":h")
    if dir == "." then
      dir = ""
    else
      dir = dir .. "/"
    end

    local line
    local dir_with_colon = dir ~= "" and ":" .. dir or ""
    if file_info.net_operation == "renamed" and file_info.old_path then
      local old_name = vim.fn.fnamemodify(file_info.old_path, ":t")
      line = string.format("%s%s %s ← %s%s", prefix, icon, name, old_name, dir_with_colon)
    else
      line = string.format("%s%s %s%s", prefix, icon, name, dir_with_colon)
    end
    table.insert(lines, line)

    local name_start = #prefix + #icon + 1
    local name_end = name_start + #name
    table.insert(extmarks, {
      line = #lines - 1,
      col = name_start,
      opts = {
        end_col = name_end,
        hl_group = "Title",
      },
    })

    if dir_with_colon ~= "" then
      local dir_start
      if file_info.net_operation == "renamed" and file_info.old_path then
        local old_name = vim.fn.fnamemodify(file_info.old_path, ":t")
        dir_start = #prefix + #icon + 1 + #name + 3 + #old_name
      else
        dir_start = #prefix + #icon + 1 + #name
      end
      table.insert(extmarks, {
        line = #lines - 1,
        col = dir_start,
        opts = {
          end_col = dir_start + #dir_with_colon,
          hl_group = "Comment",
        },
      })
    end
  end

  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  M.apply_extmarks(buf, ns, extmarks)
end

---Render checkpoints in checkpoint buffer (bottom left)
---@param buf number
---@param ns number
---@param checkpoints FSMonitor.Checkpoint[]
---@param all_changes FSMonitor.Change[]
---@param selected_idx? number
function M.render_checkpoints(buf, ns, checkpoints, all_changes, selected_idx)
  local util = require("fs-monitor.utils.util")
  local cfg = get_config()
  local lines = {}
  local extmarks = {}

  if #checkpoints == 0 then
    table.insert(lines, "No checkpoints yet")
    table.insert(lines, "")
    table.insert(lines, "Checkpoints are created after")
    table.insert(lines, "each LLM response with changes")
  else
    for idx, cp in ipairs(checkpoints) do
      local change_count = 0
      for _, change in ipairs(all_changes) do
        if change.timestamp <= cp.timestamp then change_count = change_count + 1 end
      end

      local prefix = idx == selected_idx and cfg.icons.file_selector or "  "
      local icon = cfg.icons.checkpoint
      local label
      if idx == 1 then
        label = "Initial checkpoint"
      elseif idx == #checkpoints then
        label = "Final checkpoint"
      else
        label = string.format("Cycle %d", cp.cycle or idx)
      end

      local line =
        string.format("%s%s %s - %d %s", prefix, icon, label, change_count, util.pluralize(change_count, "change"))
      table.insert(lines, line)

      local label_start = #prefix + #icon + 1
      local label_end = label_start + #label
      table.insert(extmarks, {
        line = #lines - 1,
        col = label_start,
        opts = {
          end_col = label_end,
          hl_group = "Title",
        },
      })
    end
  end

  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  M.apply_extmarks(buf, ns, extmarks)
end

return M
