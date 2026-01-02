local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        diff_utils = require("fs-monitor.diff.hunks")
      ]])
    end,
    post_once = child.stop,
  },
})

T["Diff Utils"] = new_set()

T["Diff Utils"]["calculate_hunks"] = new_set()

T["Diff Utils"]["calculate_hunks"]["returns empty for identical content"] = function()
  child.lua([[
    local lines = { "line 1", "line 2", "line 3" }
    _G.hunks = diff_utils.calculate_hunks(lines, lines)
  ]])

  local hunks = child.lua_get("_G.hunks")
  h.eq(0, #hunks)
end

T["Diff Utils"]["calculate_hunks"]["detects single line modification"] = function()
  child.lua([[
    local old_lines = { "line 1", "line 2", "line 3" }
    local new_lines = { "line 1", "modified line 2", "line 3" }
    _G.hunks = diff_utils.calculate_hunks(old_lines, new_lines)
  ]])

  local hunks = child.lua_get("_G.hunks")
  h.eq(1, #hunks)
  h.eq(1, #hunks[1].removed_lines)
  h.eq(1, #hunks[1].added_lines)
  h.eq("line 2", hunks[1].removed_lines[1])
  h.eq("modified line 2", hunks[1].added_lines[1])
end

T["Diff Utils"]["calculate_hunks"]["detects line addition"] = function()
  child.lua([[
    -- Adding a line at the end - diff algorithm may include context
    local old_lines = { "line 1", "line 2" }
    local new_lines = { "line 1", "line 2", "line 3" }
    _G.hunks = diff_utils.calculate_hunks(old_lines, new_lines)

    -- Check if line 3 is in the added lines
    _G.has_line_3 = false
    for _, line in ipairs(_G.hunks[1].added_lines) do
      if line == "line 3" then
        _G.has_line_3 = true
        break
      end
    end
  ]])

  local hunks = child.lua_get("_G.hunks")
  h.eq(1, #hunks)
  -- Must have at least one added line containing "line 3"
  h.expect_gte(#hunks[1].added_lines, 1)
  h.eq(true, child.lua_get("_G.has_line_3"))
end

T["Diff Utils"]["calculate_hunks"]["detects line deletion"] = function()
  child.lua([[
    local old_lines = { "line 1", "line 2", "line 3" }
    local new_lines = { "line 1", "line 3" }
    _G.hunks = diff_utils.calculate_hunks(old_lines, new_lines)
  ]])

  local hunks = child.lua_get("_G.hunks")
  h.eq(1, #hunks)
  h.eq(1, #hunks[1].removed_lines)
  h.eq(0, #hunks[1].added_lines)
  h.eq("line 2", hunks[1].removed_lines[1])
end

T["Diff Utils"]["calculate_hunks"]["handles multiple hunks"] = function()
  child.lua([[
    local old_lines = { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" }
    local new_lines = { "a", "MODIFIED_B", "c", "d", "e", "f", "g", "MODIFIED_H", "i", "j" }
    _G.hunks = diff_utils.calculate_hunks(old_lines, new_lines)
  ]])

  local hunks = child.lua_get("_G.hunks")
  h.eq(2, #hunks)
  h.eq("b", hunks[1].removed_lines[1])
  h.eq("MODIFIED_B", hunks[1].added_lines[1])
  h.eq("h", hunks[2].removed_lines[1])
  h.eq("MODIFIED_H", hunks[2].added_lines[1])
end

T["Diff Utils"]["calculate_hunks"]["handles empty old content (new file)"] = function()
  child.lua([[
    local old_lines = {}
    local new_lines = { "line 1", "line 2" }
    _G.hunks = diff_utils.calculate_hunks(old_lines, new_lines)
  ]])

  local hunks = child.lua_get("_G.hunks")
  h.eq(1, #hunks)
  h.eq(0, #hunks[1].removed_lines)
  h.eq(2, #hunks[1].added_lines)
end

T["Diff Utils"]["calculate_hunks"]["handles empty new content (deleted file)"] = function()
  child.lua([[
    local old_lines = { "line 1", "line 2" }
    local new_lines = {}
    _G.hunks = diff_utils.calculate_hunks(old_lines, new_lines)
  ]])

  local hunks = child.lua_get("_G.hunks")
  h.eq(1, #hunks)
  h.eq(2, #hunks[1].removed_lines)
  h.eq(0, #hunks[1].added_lines)
end

T["Diff Utils"]["calculate_hunks"]["extracts context lines"] = function()
  child.lua([[
    local old_lines = { "context1", "context2", "context3", "changed", "context4", "context5", "context6" }
    local new_lines = { "context1", "context2", "context3", "MODIFIED", "context4", "context5", "context6" }
    _G.hunks = diff_utils.calculate_hunks(old_lines, new_lines, 2)
  ]])

  local hunks = child.lua_get("_G.hunks")
  h.eq(1, #hunks)
  h.eq(2, #hunks[1].context_before)
  h.eq(2, #hunks[1].context_after)
  h.eq("context2", hunks[1].context_before[1])
  h.eq("context3", hunks[1].context_before[2])
  h.eq("context4", hunks[1].context_after[1])
  h.eq("context5", hunks[1].context_after[2])
end

T["Diff Utils"]["are_contents_equal"] = new_set()

T["Diff Utils"]["are_contents_equal"]["returns true for identical arrays"] = function()
  child.lua([[
    local a = { "line 1", "line 2", "line 3" }
    local b = { "line 1", "line 2", "line 3" }
    _G.result = diff_utils.are_contents_equal(a, b)
  ]])

  h.eq(true, child.lua_get("_G.result"))
end

T["Diff Utils"]["are_contents_equal"]["returns false for different content"] = function()
  child.lua([[
    local a = { "line 1", "line 2" }
    local b = { "line 1", "different" }
    _G.result = diff_utils.are_contents_equal(a, b)
  ]])

  h.eq(false, child.lua_get("_G.result"))
end

T["Diff Utils"]["are_contents_equal"]["returns false for different lengths"] = function()
  child.lua([[
    local a = { "line 1", "line 2" }
    local b = { "line 1", "line 2", "line 3" }
    _G.result = diff_utils.are_contents_equal(a, b)
  ]])

  h.eq(false, child.lua_get("_G.result"))
end

T["Diff Utils"]["are_contents_equal"]["returns true for empty arrays"] = function()
  child.lua([[
    _G.result = diff_utils.are_contents_equal({}, {})
  ]])

  h.eq(true, child.lua_get("_G.result"))
end

return T
