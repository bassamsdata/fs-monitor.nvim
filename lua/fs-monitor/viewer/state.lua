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
  local has_rename = false

  for _, change in ipairs(file_changes) do
    if change.kind == "renamed" then
      has_rename = true
      break
    end
  end

  local file_exists_now = last_change.kind ~= "deleted"
  local file_existed_before = first_change.kind ~= "created"

  if not file_exists_now and not file_existed_before then return "transient" end

  if not file_exists_now then return "deleted" end
  if not file_existed_before then return "created" end
  if has_rename then return "renamed" end
  return "modified"
end

---Generate summary stats from changes
---@param changes FSMonitor.Change[]
---@return table summary
function M.generate_summary(changes)
  local summary =
    { total = #changes, created = 0, modified = 0, deleted = 0, renamed = 0, transient = 0, files = {}, by_file = {} }
  local groups = {}
  local path_to_group = {}

  local function create_group(path)
    local group = {
      path = path,
      changes = {},
      net_operation = nil,
      created = 0,
      modified = 0,
      deleted = 0,
      renamed = 0,
      transient = 0,
      old_path = nil,
    }
    table.insert(groups, group)
    path_to_group[path] = group
    return group
  end

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

    local file_summary
    if change.kind == "renamed" and change.metadata and change.metadata.old_path then
      local old_path = change.metadata.old_path
      file_summary = path_to_group[old_path] or path_to_group[change.path] or create_group(change.path)
      if path_to_group[file_summary.path] == file_summary then path_to_group[file_summary.path] = nil end
      file_summary.path = change.path
      file_summary.old_path = file_summary.old_path or old_path
      path_to_group[change.path] = file_summary
    else
      file_summary = path_to_group[change.path] or create_group(change.path)
      path_to_group[change.path] = file_summary
    end

    table.insert(file_summary.changes, change)
    file_summary[change.kind] = (file_summary[change.kind] or 0) + 1
  end

  for _, file_summary in ipairs(groups) do
    summary.by_file[file_summary.path] = file_summary
    table.insert(summary.files, file_summary.path)
    file_summary.net_operation = determine_net_operation(file_summary.changes)

    if file_summary.net_operation == "transient" then summary.transient = summary.transient + 1 end
  end

  return summary
end

return M
