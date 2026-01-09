---File system operations utilities
---@module "fs-monitor.utils.fs"

local uv = vim.uv

local Fs = {}

---Safely delete a directory if empty
---@param dirpath string
---@return boolean success
---@return string|nil error
function Fs.delete_dir_if_empty(dirpath)
  local ok, err = pcall(function()
    local stat = uv.fs_stat(dirpath)
    if stat and stat.type == "directory" then
      local rmdir_ok, rmdir_err = uv.fs_rmdir(dirpath)
      if not rmdir_ok then
        if rmdir_err and not rmdir_err:match("ENOTEMPTY") then error(rmdir_err) end
      end
    end
  end)
  if not ok then return false, tostring(err) end
  return true, nil
end

---Safely rename a file with error handling
---@param old_path string
---@param new_path string
---@return boolean success
---@return string|nil error
function Fs.rename_file(old_path, new_path)
  local ok, err = pcall(function()
    local parent_dir = vim.fs.dirname(new_path)
    if parent_dir and parent_dir ~= "" then vim.fn.mkdir(parent_dir, "p") end

    local rename_ok, rename_err = uv.fs_rename(old_path, new_path)
    if not rename_ok then error(rename_err or "Failed to rename file") end
  end)
  if not ok then return false, tostring(err) end
  return true, nil
end

---Safely delete a file with error handling
---@param filepath string
---@return boolean success
---@return string|nil error
function Fs.delete_file(filepath)
  local ok, err = pcall(function()
    local stat = uv.fs_stat(filepath)
    if stat then os.remove(filepath) end
  end)
  if not ok then return false, tostring(err) end
  return true, nil
end

---Safely write content to a file with error handling
---@param filepath string
---@param content string
---@return boolean success
---@return string|nil error
function Fs.write_file(filepath, content)
  local ok, err = pcall(function()
    local parent_dir = vim.fs.dirname(filepath)
    if parent_dir and parent_dir ~= "" then vim.fn.mkdir(parent_dir, "p") end

    local fd = uv.fs_open(filepath, "w", 438)
    if not fd then error("Failed to open file for writing") end

    local write_ok, write_err = uv.fs_write(fd, content, 0)
    uv.fs_close(fd)

    if not write_ok then error(write_err or "Failed to write file") end
  end)

  if not ok then return false, tostring(err) end
  return true, nil
end

return Fs
