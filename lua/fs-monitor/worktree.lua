---@module "fs-monitor.types"

local M = {}
local util = require("fs-monitor.utils.util")
local log = require("fs-monitor.log")

---Run a git command asynchronously and return the result
---@param args string[] Git command arguments
---@param callback fun(success: boolean, stdout?: string, stderr?: string)
local function git_command(args, callback)
  local cmd = vim.list_extend({ "git" }, args)
  log:debug("Running git command: %s", table.concat(cmd, " "))

  vim.system(cmd, { text = true }, function(obj)
    local success = obj.code == 0
    callback(success, obj.stdout, obj.stderr)
  end)
end

---Get the repository root directory
---@param callback fun(success: boolean, root?: string)
local function get_repo_root(callback)
  git_command({ "rev-parse", "--show-toplevel" }, function(success, stdout, _)
    if not success or not stdout then
      callback(false)
      return
    end
    callback(true, vim.trim(stdout))
  end)
end

---Get uncommitted changes in the repository
---@param callback fun(success: boolean, changes?: string[])
local function get_uncommitted_changes(callback)
  git_command({ "status", "--porcelain" }, function(success, stdout, _)
    if not success then
      callback(false)
      return
    end

    local changes = {}
    for line in stdout:gmatch("[^\r\n]+") do
      table.insert(changes, line)
    end
    callback(true, changes)
  end)
end

---Parse git status output to extract file paths
---@param status_lines string[] Git status --porcelain output
---@return table<string, string> Map of file path to status code
local function parse_git_status(status_lines)
  local files = {}
  for _, line in ipairs(status_lines) do
    local status = line:sub(1, 2)
    local path = line:sub(4):match("^%S*")
    files[path] = status
  end
  return files
end

---Get list of changed files from session changes
---@param changes FSMonitor.Change[]
---@return string[] List of file paths
local function get_session_files(changes)
  local files = {}
  for _, change in ipairs(changes) do
    if change.old_path then table.insert(files, change.old_path) end
    table.insert(files, change.path)
  end
  return files
end

---Check if session changes are the only uncommitted changes
---@param session_changes FSMonitor.Change[]
---@param repo_changes table<string, string>
---@return boolean true if session changes are the only changes
local function are_session_changes_exclusive(session_changes, repo_changes)
  local session_files = get_session_files(session_changes)

  for path, _ in pairs(repo_changes) do
    local found = false
    for _, session_file in ipairs(session_files) do
      if path == session_file then
        found = true
        break
      end
    end
    if not found then return false end
  end

  return true
end

---Prompt user for worktree name
---@param default_name? string
---@param callback fun(name?: string) nil if user cancelled
local function prompt_worktree_name(default_name, callback)
  vim.ui.input({
    prompt = "Worktree name: ",
    default = default_name or "",
  }, function(input)
    callback(input)
  end)
end

---Prompt user about extra changes
---@param callback fun(include_all: boolean) false to cancel, true to include all
local function prompt_extra_changes(callback)
  vim.ui.select({
    { label = "Cancel", value = false },
    { label = "Include all repository changes", value = true },
  }, {
    prompt = "Other uncommitted changes exist in the repository:",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      callback(false)
    else
      callback(choice.value)
    end
  end)
end

---Copy a file from source to destination
---@param src string Source file path
---@param dst string Destination file path
---@return boolean success
local function copy_file(src, dst)
  local src_fd = vim.loop.fs_open(src, "r", 438)
  if not src_fd then return false end

  local dst_fd = vim.loop.fs_open(dst, "w", 438)
  if not dst_fd then
    vim.loop.fs_close(src_fd)
    return false
  end

  local stat = vim.loop.fs_fstat(src_fd)
  local content = vim.loop.fs_read(src_fd, stat.size, 0)
  vim.loop.fs_write(dst_fd, content, 0)
  vim.loop.fs_close(src_fd)
  vim.loop.fs_close(dst_fd)

  return true
end

---Apply session changes to worktree by copying files
---@param worktree_path string Path to the worktree
---@param changes FSMonitor.Change[]
---@return boolean success
local function apply_changes_to_worktree(worktree_path, changes)
  local repo_root = vim.fn.getcwd()

  for _, change in ipairs(changes) do
    local src_path = repo_root .. "/" .. change.path
    local dst_path = worktree_path .. "/" .. change.path

    -- Create parent directories if needed
    local dst_dir = vim.fn.fnamemodify(dst_path, ":h")
    if dst_dir ~= "." then vim.fn.mkdir(dst_dir, "p") end

    -- Handle different change types
    if change.kind == "deleted" then
      -- Delete the file in worktree
      if vim.fn.filereadable(dst_path) == 1 then vim.fn.delete(dst_path) end
    elseif change.kind == "renamed" and change.old_path then
      -- Handle rename: delete old path, create new path
      local old_dst_path = worktree_path .. "/" .. change.old_path
      if vim.fn.filereadable(old_dst_path) == 1 then vim.fn.delete(old_dst_path) end
      if change.new_content then
        local file = io.open(dst_path, "w")
        if file then
          file:write(change.new_content)
          file:close()
        end
      end
    elseif change.new_content then
      -- Write the new content to the worktree
      local file = io.open(dst_path, "w")
      if file then
        file:write(change.new_content)
        file:close()
      end
    end
  end

  return true
end

---Create a unique worktree path
---@param repo_root string Repository root directory
---@param base_name string Desired worktree name
---@return string unique_path
local function get_unique_worktree_path(repo_root, base_name)
  local worktree_path = repo_root .. "/../" .. base_name
  local counter = 1

  while vim.fn.isdirectory(worktree_path) == 1 do
    worktree_path = repo_root .. "/../" .. base_name .. "_" .. tostring(counter)
    counter = counter + 1
  end

  return worktree_path
end

---Create a worktree from session changes
---@param session_id string Session ID
---@param callback fun(success: boolean, worktree_path?: string)
function M.create_worktree(session_id, callback)
  local fs_monitor = require("fs-monitor")
  local session = fs_monitor.get_session(session_id)

  if not session then
    util.notify(string.format("Session not found: %s", session_id), vim.log.levels.ERROR)
    callback(false)
    return
  end

  if #session.changes == 0 then
    util.notify("Session has no recorded changes", vim.log.levels.WARN)
    callback(false)
    return
  end

  -- Check if we're in a git repository
  get_repo_root(function(success, repo_root)
    if not success then
      util.notify("Not a git repository", vim.log.levels.ERROR)
      callback(false)
      return
    end

    -- Get uncommitted changes
    get_uncommitted_changes(function(success, status_lines)
      if not success then
        util.notify("Failed to get repository status", vim.log.levels.ERROR)
        callback(false)
        return
      end

      local repo_changes = parse_git_status(status_lines)
      local is_exclusive = are_session_changes_exclusive(session.changes, repo_changes)

      if not is_exclusive then
        -- Prompt user about extra changes
        prompt_extra_changes(function(include_all)
          if not include_all then
            util.notify("Worktree creation cancelled", vim.log.levels.INFO)
            callback(false)
            return
          end
          -- User chose to include all changes, proceed
          create_worktree_impl(session, repo_root, callback)
        end)
      else
        -- Session changes are exclusive, proceed directly
        create_worktree_impl(session, repo_root, callback)
      end
    end)
  end)
end

---Internal implementation to create the worktree
---@param session FSMonitor.Session
---@param repo_root string
---@param callback fun(success: boolean, worktree_path?: string)
local function create_worktree_impl(session, repo_root, callback)
  -- Prompt for worktree name
  prompt_worktree_name(session.id, function(worktree_name)
    if not worktree_name or worktree_name == "" then
      util.notify("Worktree creation cancelled", vim.log.levels.INFO)
      callback(false)
      return
    end

    local worktree_path = get_unique_worktree_path(repo_root, worktree_name)
    local branch_name = "worktree-" .. worktree_name

    -- Create the worktree using git
    git_command({ "worktree", "add", "-b", branch_name, worktree_path }, function(success, _, stderr)
      if not success then
        util.notify(string.format("Failed to create worktree: %s", stderr or "unknown error"), vim.log.levels.ERROR)
        callback(false)
        return
      end

      -- Apply session changes to the worktree
      local apply_success = apply_changes_to_worktree(worktree_path, session.changes)
      if not apply_success then
        util.notify("Failed to apply changes to worktree", vim.log.levels.ERROR)
        callback(false)
        return
      end

      util.notify(
        string.format("Worktree created: %s\nBranch: %s\nPath: %s", worktree_name, branch_name, worktree_path),
        vim.log.levels.INFO
      )
      callback(true, worktree_path)
    end)
  end)
end

return M
