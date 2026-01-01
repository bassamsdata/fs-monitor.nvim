---@class FSMonitor.Gitignore
local M = {}

---@class FSMonitor.GitignorePattern
---@field pattern string Lua pattern to match
---@field negated boolean Whether this is a negation pattern (starts with !)
---@field dir_only boolean Whether this pattern only matches directories (ends with /)
---@field anchored boolean Whether pattern is anchored to root (starts with /)

---Convert a gitignore glob pattern to a Lua pattern
---@param glob string The gitignore glob pattern
---@return string lua_pattern
function M.glob_to_lua_pattern(glob)
  local pattern = glob

  -- Escape special Lua pattern characters (except * and ?)
  pattern = pattern:gsub("([%.%+%-%[%]%^%$%(%)%%])", "%%%1")

  -- Handle ** (match any path including /)
  -- Replace ** with a placeholder first to avoid conflicts
  pattern = pattern:gsub("%*%*", "__DOUBLESTAR__")

  -- Handle * (match anything except /)
  pattern = pattern:gsub("%*", "[^/]*")

  -- Handle ? (match single char except /)
  pattern = pattern:gsub("%?", "[^/]")

  -- Restore ** as .* (matches anything including /)
  pattern = pattern:gsub("__DOUBLESTAR__", ".*")

  return pattern
end

---Parse a single gitignore line into a pattern object
---@param line string The gitignore line
---@return FSMonitor.GitignorePattern|nil
function M.parse_line(line)
  -- Trim whitespace
  line = line:match("^%s*(.-)%s*$")

  -- Skip empty lines and comments
  if line == "" or line:match("^#") then return nil end

  local negated = false
  local dir_only = false
  local anchored = false

  -- Check for negation (!)
  if line:sub(1, 1) == "!" then
    negated = true
    line = line:sub(2)
  end

  -- Check for directory-only pattern (trailing /)
  if line:sub(-1) == "/" then
    dir_only = true
    line = line:sub(1, -2)
  end

  -- Check if anchored (contains / not at end, or starts with /)
  if line:sub(1, 1) == "/" then
    anchored = true
    line = line:sub(2)
  elseif line:find("/") then
    -- Contains / in middle - anchored to root
    anchored = true
  end

  -- Convert to Lua pattern
  local lua_pattern = M.glob_to_lua_pattern(line)

  -- Build final pattern
  if anchored then
    -- Anchored: must match from root
    lua_pattern = "^/?" .. lua_pattern
  else
    -- Not anchored: can match anywhere in path
    lua_pattern = "/" .. lua_pattern
  end

  -- Add end anchor or allow trailing content
  if dir_only then
    lua_pattern = lua_pattern .. "/"
  else
    lua_pattern = lua_pattern .. "$"
  end

  return {
    pattern = lua_pattern,
    negated = negated,
    dir_only = dir_only,
    anchored = anchored,
  }
end

-- Built-in patterns that are always ignored
M.BUILTIN_PATTERNS = {
  "^/?%.git/",
  "^/?%.git$",
  "/%.git/",
  "/node_modules/",
  "/node_modules$",
  "%.DS_Store$",
  "%.swp$",
  "%.swo$",
  "%.tmp$",
  "%.bak$",
  "~$",
}

---Check if a file path matches any of the built-in ignore patterns
---@param normalized_path string Path normalized with leading /
---@return boolean
function M.matches_builtin_pattern(normalized_path)
  for _, pattern in ipairs(M.BUILTIN_PATTERNS) do
    if normalized_path:match(pattern) then return true end
  end
  return false
end

---Check if a file should be ignored based on gitignore patterns
---@param filepath string The file path to check
---@param ignore_patterns FSMonitor.GitignorePattern[] Parsed gitignore patterns
---@param custom_patterns? string[] Additional custom patterns
---@return boolean should_ignore
function M.should_ignore(filepath, ignore_patterns, custom_patterns)
  -- Normalize path to use forward slashes and ensure leading /
  local normalized = "/" .. filepath:gsub("\\", "/")

  -- Check built-in patterns first
  if M.matches_builtin_pattern(normalized) then return true end

  -- Check .gitignore patterns (order matters for negation)
  local ignored = false
  for _, pat in ipairs(ignore_patterns) do
    local matches = normalized:match(pat.pattern) ~= nil

    if matches then
      if pat.negated then
        ignored = false
      else
        ignored = true
      end
    end
  end

  if ignored then return true end

  -- Check custom ignore patterns (simple string patterns)
  if custom_patterns then
    for _, pattern in ipairs(custom_patterns) do
      if normalized:match(pattern) then return true end
    end
  end

  return false
end

---Load and parse .gitignore patterns from a file
---@param gitignore_path string Full path to .gitignore file
---@return FSMonitor.GitignorePattern[] patterns
function M.load_patterns(gitignore_path)
  local uv = vim.uv
  local patterns = {}

  local stat = uv.fs_stat(gitignore_path)
  if not stat then return patterns end

  local fd = uv.fs_open(gitignore_path, "r", 438)
  if not fd then return patterns end

  local fstat = uv.fs_fstat(fd)
  if not fstat then
    uv.fs_close(fd)
    return patterns
  end

  local data = uv.fs_read(fd, fstat.size, 0)
  uv.fs_close(fd)

  if not data then return patterns end

  for line in data:gmatch("[^\r\n]+") do
    local parsed = M.parse_line(line)
    if parsed then table.insert(patterns, parsed) end
  end

  return patterns
end

return M
