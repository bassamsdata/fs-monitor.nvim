local Helpers = {}

-- Expectation helpers
--- @param desc? string
Helpers.eq = function(a, b, desc)
  desc = desc or ""
  if not vim.deep_equal(a, b) then error(string.format("Expected %s, but got %s", vim.inspect(a), vim.inspect(b))) end
end

Helpers.not_eq = function(a, b)
  if vim.deep_equal(a, b) then
    error(string.format("Expected %s and %s to be different", vim.inspect(a), vim.inspect(b)))
  end
end

---@param desc? string
Helpers.expect_contains = function(needle, haystack, desc)
  desc = desc or ""
  if not string.find(haystack, needle, 1, true) then
    error(string.format("Expected %s to contain %s", vim.inspect(haystack), vim.inspect(needle)))
  end
end

Helpers.expect_true = function(value, msg)
  if not value then error(msg or string.format("Expected true, but got %s", vim.inspect(value))) end
end

Helpers.expect_false = function(value, msg)
  if value then error(msg or string.format("Expected false, but got %s", vim.inspect(value))) end
end

Helpers.expect_nil = function(value, msg)
  if value ~= nil then error(msg or string.format("Expected nil, but got %s", vim.inspect(value))) end
end

Helpers.expect_not_nil = function(value, msg)
  if value == nil then error(msg or "Expected non-nil value, but got nil") end
end

Helpers.expect_gte = function(a, b, msg)
  if not (a >= b) then error(msg or string.format("Expected %s >= %s", vim.inspect(a), vim.inspect(b))) end
end

Helpers.expect_gt = function(a, b, msg)
  if not (a > b) then error(msg or string.format("Expected %s > %s", vim.inspect(a), vim.inspect(b))) end
end

Helpers.child_start = function(child)
  child.restart({ "-u", "scripts/minimal_init.lua" })
  child.o.statusline = ""
  child.o.laststatus = 0
  child.o.cmdheight = 1

  if not child.wait then
    child.wait = function(ms, condition)
      if condition == nil then
        vim.loop.sleep(ms)
        return true
      end

      local check = function()
        return child.lua_get(condition)
      end

      return vim.wait(ms, check)
    end
  end
end

---Create a mock change object for testing
---@param opts table { path, kind, old_content?, new_content?, timestamp?, tool_name? }
---@return table change
Helpers.create_mock_change = function(opts)
  return {
    path = opts.path or "test.txt",
    kind = opts.kind or "modified",
    old_content = opts.old_content,
    new_content = opts.new_content,
    timestamp = opts.timestamp or vim.uv.hrtime(),
    tool_name = opts.tool_name or "workspace",
    metadata = opts.metadata or {},
  }
end

---Create multiple mock changes from a spec list
---@param specs table[] Array of change specs
---@return table[] changes
Helpers.create_mock_changes = function(specs)
  local changes = {}
  local base_time = vim.uv.hrtime()
  for i, spec in ipairs(specs) do
    spec.timestamp = spec.timestamp or (base_time + (i * 1000000)) -- 1ms apart
    table.insert(changes, Helpers.create_mock_change(spec))
  end
  return changes
end

---Create a mock checkpoint
---@param opts table { timestamp?, change_count?, label?, cycle? }
---@return table checkpoint
Helpers.create_mock_checkpoint = function(opts)
  return {
    timestamp = opts.timestamp or vim.uv.hrtime(),
    change_count = opts.change_count or 0,
    label = opts.label,
    cycle = opts.cycle,
  }
end

---Assert a change has expected properties
---@param change table The change to check
---@param expected table Expected properties (partial match)
Helpers.assert_change_matches = function(change, expected)
  for key, value in pairs(expected) do
    if change[key] ~= value then
      error(
        string.format("Change property '%s' expected %s, got %s", key, vim.inspect(value), vim.inspect(change[key]))
      )
    end
  end
end

---Assert changes list contains a change matching a pattern
---@param changes table[] List of changes
---@param pattern table Pattern to match (partial)
---@return table|nil The matching change
Helpers.find_change_matching = function(changes, pattern)
  for _, change in ipairs(changes) do
    local matches = true
    for key, value in pairs(pattern) do
      if change[key] ~= value then
        matches = false
        break
      end
    end
    if matches then return change end
  end
  return nil
end

---Split content string into lines
---@param content string
---@return string[]
Helpers.split_lines = function(content)
  local lines = {}
  for line in content:gmatch("[^\r\n]*") do
    table.insert(lines, line)
  end
  -- Remove trailing empty line if content ends with newline
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
  return lines
end

return Helpers
