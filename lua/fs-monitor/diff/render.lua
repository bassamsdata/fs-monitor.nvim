---@module "fs-monitor.types"

---@class FSMonitor.Render
local Render = {}

local api = vim.api
local constants = require("fs-monitor.diff.constants")
local fmt = string.format

local LINE_HIGHLIGHT_PRIORITY = constants.LINE_HIGHLIGHT_PRIORITY

Render.__index = Render

---Create a new render instance
---@param buf number
---@param ns number
---@return FSMonitor.Render
function Render.new(buf, ns)
  return setmetatable({
    buf = buf,
    ns = ns,
    lines = {},
    extmarks = {},
    line_mappings = {},
    hunk_ranges = {},
    cfg = require("fs-monitor.config").diff_options,
  }, Render)
end

---Add a line to the render
---@private
---@param line string
---@param mapping? table
---@return number (0-based)
function Render:_add_line(line, mapping)
  table.insert(self.lines, line == "" and " " or line)
  if mapping then self.line_mappings[#self.lines - 1] = mapping end
  return #self.lines - 1
end

---Add an extmark to the current or specified line
---@private
---@param opts table Extmark options
---@param line_idx? number (0-based), defaults to current line
function Render:_add_mark(opts, line_idx)
  local col = opts.col or 0
  local extmark_opts = vim.tbl_extend("force", {}, opts)
  extmark_opts.col = nil

  table.insert(self.extmarks, {
    line = line_idx or (#self.lines - 1),
    col = col,
    opts = extmark_opts,
  })
end

---Apply the rendered lines and extmarks to the buffer
---@private
function Render:_apply()
  api.nvim_buf_set_lines(self.buf, 0, -1, false, self.lines)
  for _, mark in ipairs(self.extmarks) do
    pcall(api.nvim_buf_set_extmark, self.buf, self.ns, mark.line, mark.col, mark.opts)
  end
end

---Render context lines
---@private
---@param lines string[]
---@param start_nr number
---@param sign_text string
function Render:_render_context(lines, start_nr, sign_text)
  for idx, line in ipairs(lines) do
    local line_nr = start_nr + idx - 1
    self:_add_line(line, { original_line = line_nr, updated_line = line_nr, type = "context" })
    self:_add_mark({
      end_row = #self.lines,
      end_col = 0,
      hl_group = "FSMonitorContext",
      hl_eol = true,
      priority = LINE_HIGHLIGHT_PRIORITY,
      virt_text = { { fmt("%4d  %4d ", line_nr, line_nr), "FSMonitorContextLineNr" } },
      virt_text_pos = "inline",
      hl_mode = "replace",
      sign_text = sign_text,
      sign_hl_group = "FSMonitorContextLineNr",
    })
  end
end

---Render diff lines (added/removed)
---@private
---@param lines string[]
---@param start_nr number
---@param type "added"|"removed"
---@param sign_text string
---@param is_modified boolean
function Render:_render_diff_lines(lines, start_nr, type, sign_text, is_modified)
  local is_removed = type == "removed"
  local hl_group = is_removed and "FSMonitorDelete" or "FSMonitorAdd"
  local nr_hl = is_removed and "FSMonitorDeleteLineNr" or "FSMonitorAddLineNr"
  local sign_hl = is_modified and "FSMonitorChangeLineNr" or nr_hl

  for idx, line in ipairs(lines) do
    local line_nr = start_nr + idx - 1
    local mapping = {
      original_line = is_removed and line_nr or nil,
      updated_line = not is_removed and line_nr or nil,
      type = type,
    }

    self:_add_line(line, mapping)
    self:_add_mark({
      end_row = #self.lines,
      end_col = 0,
      hl_group = hl_group,
      hl_eol = true,
      priority = LINE_HIGHLIGHT_PRIORITY,
      virt_text = {
        {
          is_removed and fmt("%4d       ", line_nr) or fmt("      %4d ", line_nr),
          nr_hl,
        },
      },
      virt_text_pos = "inline",
      sign_text = sign_text,
      sign_hl_group = sign_hl,
    })
  end
end

---Render the main diff view
---@param hunks FSMonitor.Diff.Hunk[]
---@param word_diff? boolean
---@return number line_count
---@return table line_mappings
---@return table hunk_ranges
function Render:render_diff(hunks, word_diff)
  local sign_text = self.cfg.icons.sign
  local total_hunks = #hunks

  for hunk_idx, hunk in ipairs(hunks) do
    local hunk_start_line = #self.lines + 1

    local header_base =
      fmt("@@ -%d,%d +%d,%d @@", hunk.original_start, hunk.original_count, hunk.updated_start, hunk.updated_count)
    local hunk_number = fmt(" [%d/%d]", hunk_idx, total_hunks)
    local header = header_base .. hunk_number

    self:_add_line(header)
    self:_add_mark({ end_col = #header_base, hl_group = "FSMonitorHeader" })
    self:_add_mark({
      col = #header_base,
      end_col = #header_base + #hunk_number,
      hl_group = "FSMonitorSpecial",
    })

    self:_render_context(hunk.context_before, hunk.original_start - #hunk.context_before, sign_text)

    local is_modified = #hunk.removed_lines > 0 and #hunk.added_lines > 0
    self:_render_diff_lines(hunk.removed_lines, hunk.original_start, "removed", sign_text, is_modified)
    self:_render_diff_lines(hunk.added_lines, hunk.updated_start, "added", sign_text, is_modified)

    self:_render_context(hunk.context_after, hunk.original_start + hunk.original_count, sign_text)

    table.insert(self.hunk_ranges, { start_line = hunk_start_line, end_line = #self.lines })

    if hunk_idx < #hunks then
      self:_add_line("")
      self:_add_line("")
    end
  end

  if #self.lines == 0 then
    self:_add_line("")
    self:_add_line("No differences detected")
    self:_add_line("")
  end

  self:_apply()

  if word_diff then
    require("fs-monitor.diff.word_diff").apply_word_highlights({
      bufnr = self.buf,
      ns_id = self.ns,
      hunks = hunks,
      line_mappings = self.line_mappings,
      hunk_ranges = self.hunk_ranges,
    })
  end

  return #self.lines, self.line_mappings, self.hunk_ranges
end

---Render the file list panel
---@param files string[]
---@param by_file table
---@param selected_idx? number
function Render:render_file_list(files, by_file, selected_idx)
  for idx, filepath in ipairs(files) do
    local file_info = by_file[filepath]
    local icon = self.cfg.icons[file_info.net_operation] or " "
    local prefix = idx == selected_idx and self.cfg.icons.file_selector or "  "
    local name = vim.fn.fnamemodify(filepath, ":t")
    local dir = vim.fn.fnamemodify(filepath, ":h")
    dir = dir == "." and "" or dir .. "/"

    local line
    local dir_with_colon = dir ~= "" and ":" .. dir or ""
    if file_info.net_operation == "renamed" and file_info.old_path then
      local old_name = vim.fn.fnamemodify(file_info.old_path, ":t")
      line = fmt("%s%s %s ← %s%s", prefix, icon, name, old_name, dir_with_colon)
    else
      line = fmt("%s%s %s%s", prefix, icon, name, dir_with_colon)
    end

    self:_add_line(line)
    local name_start = #prefix + #icon + 1
    self:_add_mark({ col = name_start, end_col = name_start + #name, hl_group = "Title" }, #self.lines - 1)

    if dir_with_colon ~= "" then
      local dir_start = name_start + #name
      if file_info.net_operation == "renamed" and file_info.old_path then
        dir_start = dir_start + 3 + #vim.fn.fnamemodify(file_info.old_path, ":t")
      end
      self:_add_mark({ col = dir_start, end_col = dir_start + #dir_with_colon, hl_group = "Comment" }, #self.lines - 1)
    end
  end
  self:_apply()
end

---Render the checkpoints panel
---@param checkpoints FSMonitor.Checkpoint[]
---@param all_changes FSMonitor.Change[]
---@param selected_idx? number
function Render:render_checkpoints(checkpoints, all_changes, selected_idx)
  if #checkpoints == 0 then
    self:_add_line("No checkpoints yet")
    self:_add_line("")
    self:_add_line("Checkpoints are created after")
    self:_add_line("each LLM response with changes")
  else
    local util = require("fs-monitor.utils.util")
    for idx, cp in ipairs(checkpoints) do
      local change_count = 0
      for _, change in ipairs(all_changes) do
        if change.timestamp <= cp.timestamp then change_count = change_count + 1 end
      end

      local prefix = idx == selected_idx and self.cfg.icons.file_selector or "  "
      local icon = self.cfg.icons.checkpoint
      local label = idx == 1 and "Initial checkpoint"
        or (idx == #checkpoints and "Final checkpoint" or fmt("Cycle %d", cp.cycle or idx))

      local line = fmt("%s%s %s - %d %s", prefix, icon, label, change_count, util.pluralize(change_count, "change"))
      self:_add_line(line)
      local label_start = #prefix + #icon + 1
      self:_add_mark({ col = label_start, end_col = label_start + #label, hl_group = "Title" })
    end
  end
  self:_apply()
end

return Render
