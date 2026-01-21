---@module "fs-monitor.types"

---@class FSMonitor.Viewer.State
local M = {}

---Determine the net operation for a file across all changes in a session
---@param file_changes FSMonitor.Change[]
---@return FSMonitor.Change.Kind
local function determine_net_operation(file_changes)
  if #file_changes == 0 then return "modified" end

  local first_change = file_changes[1]
  local last_change = file_changes[#file_changes]

  for _, change in ipairs(file_changes) do
    if change.kind == "renamed" then return "renamed" end
  end

  local file_exists_now = last_change.kind ~= "deleted"
  local file_existed_before = first_change.kind ~= "created"

  if not file_exists_now and not file_existed_before then return "transient" end

  if not file_exists_now then
    return "deleted"
  elseif not file_existed_before then
    return "created"
  else
    return "modified"
  end
end

---Generate summary stats from changes
---@param changes FSMonitor.Change[]
---@return table summary
function M.generate_summary(changes)
  local summary =
    { total = #changes, created = 0, modified = 0, deleted = 0, renamed = 0, transient = 0, files = {}, by_file = {} }

  for _, change in ipairs(changes) do
    if change.kind == "created" then
      summary.created = summary.created + 1
    elseif change.kind == "modified" then
      summary.modified = summary.modified + 1
    elseif change.kind == "deleted" then
      summary.deleted = summary.deleted + 1
    elseif change.kind == "renamed" then
      summary.renamed = summary.renamed + 1
    end

    if not summary.by_file[change.path] then
      summary.by_file[change.path] = {
        path = change.path,
        changes = {},
        net_operation = nil,
        created = 0,
        modified = 0,
        deleted = 0,
        renamed = 0,
        transient = 0,
        old_path = nil,
      }
      table.insert(summary.files, change.path)
    end

    local file_summary = summary.by_file[change.path]
    table.insert(file_summary.changes, change)
    file_summary[change.kind] = (file_summary[change.kind] or 0) + 1

    if change.kind == "renamed" and change.metadata and change.metadata.old_path then
      file_summary.old_path = change.metadata.old_path
    end
  end

  for _, filepath in ipairs(summary.files) do
    local file_summary = summary.by_file[filepath]
    file_summary.net_operation = determine_net_operation(file_summary.changes)

    if file_summary.net_operation == "transient" then summary.transient = summary.transient + 1 end
  end

  return summary
end

return M
