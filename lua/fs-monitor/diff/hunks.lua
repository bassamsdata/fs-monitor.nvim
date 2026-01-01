---@module "fs-monitor.types"

local M = {}

---Calculate diff hunks between two content arrays
---@param removed_lines string[]
---@param added_lines string[]
---@param context_lines? number Number of context lines (default: 3)
---@return FSMonitor.Diff.Hunk[] hunks
function M.calculate_hunks(removed_lines, added_lines, context_lines)
  context_lines = context_lines or 3

  ---@diagnostic disable-next-line: deprecated
  local diff_engine = vim.text.diff or vim.diff
  local original_text = table.concat(removed_lines, "\n")
  local updated_text = table.concat(added_lines, "\n")
  local ok, diff_result = pcall(diff_engine, original_text, updated_text, {
    result_type = "indices",
    algorithm = "histogram",
  })

  if not ok or not diff_result or #diff_result == 0 then return {} end

  local hunks = {}
  for _, hunk in ipairs(diff_result) do
    ---@diagnostic disable-next-line: deprecated
    local original_start, original_count, updated_start, updated_count = unpack(hunk)

    local original_hunk_lines = {}
    for i = 0, original_count - 1 do
      local original_line_index = original_start + i
      if removed_lines[original_line_index] then
        table.insert(original_hunk_lines, removed_lines[original_line_index])
      end
    end

    local updated_hunk_lines = {}
    for i = 0, updated_count - 1 do
      local original_line_index = updated_start + i
      if added_lines[original_line_index] then table.insert(updated_hunk_lines, added_lines[original_line_index]) end
    end

    local context_before = {}
    local context_start = math.max(1, original_start - context_lines)
    for i = context_start, original_start - 1 do
      if removed_lines[i] then table.insert(context_before, removed_lines[i]) end
    end

    local context_after = {}
    local context_end = math.min(#removed_lines, original_start + original_count + context_lines - 1)
    for i = original_start + original_count, context_end do
      if removed_lines[i] then table.insert(context_after, removed_lines[i]) end
    end
    table.insert(hunks, {
      original_start = original_start,
      original_count = original_count,
      updated_start = updated_start,
      updated_count = updated_count,
      removed_lines = original_hunk_lines,
      added_lines = updated_hunk_lines,
      context_before = context_before,
      context_after = context_after,
    })
  end

  return hunks
end

---Determine if two content arrays are equal
---@param content1 string[]
---@param content2 string[]
---@return boolean
function M.are_contents_equal(content1, content2)
  if #content1 ~= #content2 then return false end
  for i = 1, #content1 do
    if content1[i] ~= content2[i] then return false end
  end
  return true
end

return M
