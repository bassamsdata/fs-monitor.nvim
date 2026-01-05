---@class FSMonitor.Diff.WordDiff
--[[
This module implements word-level diffing to highlight granular changes within lines.
Many functions was copied and modified by the excellent inline word diffing implementation in sidekick.nvim by folke.
]]
local M = {}

local constants = require("fs-monitor.diff.constants")

local MAX_LINES_FOR_WORD_DIFF = constants.MAX_LINES_FOR_WORD_DIFF
local WORD_HIGHLIGHT_PRIORITY = constants.WORD_HIGHLIGHT_PRIORITY

---Split string into words using Vim's keyword detection
---@private
---@param str string
---@return table[] {word: string, start_col: number, end_col: number}
local function _split_words(str)
  if str == "" then return {} end

  local words = {}
  local word_chars = {}
  local word_start_byte = nil
  local current_byte = 0

  local starts = vim.str_utf_pos(str)

  local function flush_word()
    if #word_chars > 0 then
      local word_text = table.concat(word_chars)
      words[#words + 1] = {
        word = word_text,
        start_col = word_start_byte,
        end_col = current_byte,
      }
      word_chars = {}
      word_start_byte = nil
    end
  end

  for idx, utf_start in ipairs(starts) do
    local utf_stop = (starts[idx + 1] or (#str + 1)) - 1
    local ch = str:sub(utf_start, utf_stop)
    local ch_len = #ch

    if vim.fn.charclass(ch) == 2 then
      if word_start_byte == nil then word_start_byte = current_byte end
      word_chars[#word_chars + 1] = ch
    else
      flush_word()
      words[#words + 1] = {
        word = ch,
        start_col = current_byte,
        end_col = current_byte + ch_len,
      }
    end

    current_byte = current_byte + ch_len
  end

  flush_word()
  return words
end

---Calculate word-level diff for a single line pair
---@private
---@param old_line string
---@param new_line string
---@return table|nil word_changes {old_ranges: {start_col, end_col}[], new_ranges: {start_col, end_col}[]} or nil
local function _diff_words_line(old_line, new_line)
  if old_line == "" or new_line == "" then return nil end

  local old_words = _split_words(old_line)
  local new_words = _split_words(new_line)

  if #old_words == 0 or #new_words == 0 then return nil end

  local old_text = table.concat(
    vim.tbl_map(function(w)
      return w.word
    end, old_words),
    "\n"
  )
  local new_text = table.concat(
    vim.tbl_map(function(w)
      return w.word
    end, new_words),
    "\n"
  )

  ---@diagnostic disable-next-line: deprecated
  local diff_engine = vim.text.diff or vim.diff
  local ok, hunks = pcall(diff_engine, old_text, new_text, {
    result_type = "indices",
    algorithm = "histogram",
  })

  if not ok or not hunks or #hunks == 0 then return nil end

  ---@cast hunks integer[][]
  local old_ranges = {}
  local new_ranges = {}

  for _, hunk in ipairs(hunks) do
    ---@diagnostic disable-next-line: deprecated
    local ai, ac, bi, bc = unpack(hunk)

    if ac > 0 then
      local start_word_idx = ai
      local end_word_idx = ai + ac - 1

      if old_words[start_word_idx] and old_words[end_word_idx] then
        local start_col = old_words[start_word_idx].start_col
        local end_col = old_words[end_word_idx].end_col

        table.insert(old_ranges, { start_col = start_col, end_col = end_col })
      end
    end

    if bc > 0 then
      local start_word_idx = bi
      local end_word_idx = bi + bc - 1

      if new_words[start_word_idx] and new_words[end_word_idx] then
        local start_col = new_words[start_word_idx].start_col
        local end_col = new_words[end_word_idx].end_col

        table.insert(new_ranges, { start_col = start_col, end_col = end_col })
      end
    end
  end

  if #old_ranges > 0 or #new_ranges > 0 then return { old_ranges = old_ranges, new_ranges = new_ranges } end

  return nil
end

---Calculate word-level diffs for a hunk
---@param hunk FSMonitor.Diff.Hunk
---@return table|nil word_diffs {line_idx: {old_ranges, new_ranges}} or nil if not applicable
function M._calculate_word_diffs(hunk)
  if #hunk.removed_lines ~= #hunk.added_lines then return nil end
  if #hunk.removed_lines == 0 or #hunk.removed_lines > MAX_LINES_FOR_WORD_DIFF then return nil end

  local word_diffs = {}
  local has_changes = false

  for i = 1, #hunk.removed_lines do
    local old_line = hunk.removed_lines[i]
    local new_line = hunk.added_lines[i]

    if old_line ~= new_line then
      local line_diff = _diff_words_line(old_line, new_line)
      if line_diff then
        word_diffs[i] = line_diff
        has_changes = true
      end
    end
  end

  return has_changes and word_diffs or nil
end

---Apply word-level highlights to diff buffer
---@param args { bufnr: number, ns_id: number, hunks: FSMonitor.Diff.Hunk[], line_mappings: table, hunk_ranges: table[] }
function M.apply_word_highlights(args)
  local bufnr = args.bufnr
  local ns_id = args.ns_id
  local hunks = args.hunks
  local line_mappings = args.line_mappings
  local hunk_ranges = args.hunk_ranges

  for hunk_idx, hunk in ipairs(hunks) do
    local word_diffs = M._calculate_word_diffs(hunk)
    if word_diffs then
      local hunk_range = hunk_ranges[hunk_idx]
      if not hunk_range then goto continue end

      local removed_line_start = nil
      local added_line_start = nil

      for line_idx = hunk_range.start_line - 1, hunk_range.end_line - 1 do
        local mapping = line_mappings[line_idx]
        if mapping then
          if mapping.type == "removed" and not removed_line_start then
            removed_line_start = line_idx
          elseif mapping.type == "added" and not added_line_start then
            added_line_start = line_idx
          end
        end
      end

      if removed_line_start and added_line_start then
        for rel_idx, line_diff in pairs(word_diffs) do
          local del_line = removed_line_start + rel_idx - 1
          local add_line = added_line_start + rel_idx - 1

          for _, range in ipairs(line_diff.old_ranges) do
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, del_line, range.start_col, {
              end_col = range.end_col,
              hl_group = "FSMonitorDeleteWord",
              priority = WORD_HIGHLIGHT_PRIORITY,
            })
          end

          for _, range in ipairs(line_diff.new_ranges) do
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, add_line, range.start_col, {
              end_col = range.end_col,
              hl_group = "FSMonitorAddWord",
              priority = WORD_HIGHLIGHT_PRIORITY,
            })
          end
        end
      end
    end
    ::continue::
  end
end

return M
