local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        Render = require("fs-monitor.diff.render")
        _G.api = vim.api
      ]])
    end,
    post_case = function()
      child.lua([[
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
          end
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["Render"] = new_set()

T["Render"]["new()"] = function()
  child.lua([[
    local bufnr = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace("test_ns")
    _G.render = Render.new(bufnr, ns)
  ]])
  local render = child.lua_get("_G.render")
  h.expect_not_nil(render.buf)
  h.expect_not_nil(render.ns)
  h.eq({}, render.lines)
  h.eq({}, render.extmarks)
  h.eq({}, render.line_mappings)
  h.eq({}, render.hunk_ranges)
end

T["Render"]["_add_mark()"] = function()
  child.lua([[
    local bufnr = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace("test_ns")
    local r = Render.new(bufnr, ns)
    r:_add_line("line1")
    r:_add_mark({ hl_group = "MyHl", col = 0 })
    r:_add_mark({ hl_group = "MyHl2" }, 0)
    _G.extmarks = r.extmarks
  ]])
  local extmarks = child.lua_get("_G.extmarks")
  h.eq(2, #extmarks)
  h.eq(0, extmarks[1].line)
  h.eq("MyHl", extmarks[1].opts.hl_group)
  h.eq(0, extmarks[2].line)
  h.eq("MyHl2", extmarks[2].opts.hl_group)
end

T["Render"]["_apply()"] = function()
  child.lua([[
    local bufnr = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace("test_ns")
    local r = Render.new(bufnr, ns)
    r:_add_line("line1")
    r:_add_mark({ hl_group = "Comment" })
    r:_apply()
    _G.test_buf = bufnr
    _G.test_ns = ns
  ]])
  local lines = child.lua_get("api.nvim_buf_get_lines(_G.test_buf, 0, -1, false)")
  h.eq({ "line1" }, lines)
  local marks = child.lua_get("api.nvim_buf_get_extmarks(_G.test_buf, _G.test_ns, 0, -1, { details = true })")
  h.eq(1, #marks)
  h.eq("Comment", marks[1][4].hl_group)
end

T["Render"]["_render_context()"] = function()
  child.lua([[
    local bufnr = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace("test_ns")
    local r = Render.new(bufnr, ns)
    r:_render_context({ "context1" }, 10, ">>")
    _G.lines = r.lines
    _G.mapping0 = r.line_mappings[0]
    _G.extmarks = r.extmarks
  ]])
  local lines = child.lua_get("_G.lines")
  h.eq({ "context1" }, lines)
  local mapping0 = child.lua_get("_G.mapping0")
  h.eq({ original_line = 10, updated_line = 10, type = "context" }, mapping0)
  local extmarks = child.lua_get("_G.extmarks")
  h.eq("FSMonitorContext", extmarks[1].opts.hl_group)
  h.eq(">>", extmarks[1].opts.sign_text)
end

T["Render"]["_render_diff_lines()"] = function()
  child.lua([[
    local bufnr = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace("test_ns")
    local r = Render.new(bufnr, ns)
    r:_render_diff_lines({ "added1" }, 20, "added", "+", false)
    r:_render_diff_lines({ "removed1" }, 30, "removed", "-", false)
    _G.lines = r.lines
    _G.mapping0 = r.line_mappings[0]
    _G.mapping1 = r.line_mappings[1]
    _G.extmarks = r.extmarks
  ]])
  local lines = child.lua_get("_G.lines")
  h.eq({ "added1", "removed1" }, lines)

  local mapping0 = child.lua_get("_G.mapping0")
  h.eq({ updated_line = 20, type = "added" }, mapping0)
  local mapping1 = child.lua_get("_G.mapping1")
  h.eq({ original_line = 30, type = "removed" }, mapping1)

  local extmarks = child.lua_get("_G.extmarks")
  h.eq("FSMonitorAdd", extmarks[1].opts.hl_group)
  h.eq("FSMonitorDelete", extmarks[2].opts.hl_group)
end

T["Render"]["render_diff()"] = function()
  child.lua([[
    local bufnr = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace("test_ns")
    local r = Render.new(bufnr, ns)
    local hunks = {
      {
        original_start = 1, original_count = 1,
        updated_start = 1, updated_count = 1,
        context_before = { "before" },
        removed_lines = { "old" },
        added_lines = { "new" },
        context_after = { "after" },
      }
    }
    _G.line_count, _G.mappings, _G.hunk_ranges = r:render_diff(hunks)
    _G.test_buf = bufnr
  ]])
  local line_count = child.lua_get("_G.line_count")
  h.eq(5, line_count) -- header, before, old, new, after

  local lines = child.lua_get("api.nvim_buf_get_lines(_G.test_buf, 0, -1, false)")
  h.expect_contains("@@ -1,1 +1,1 @@", lines[1])
  h.eq("before", lines[2])
  h.eq("old", lines[3])
  h.eq("new", lines[4])
  h.eq("after", lines[5])

  local hunk_ranges = child.lua_get("_G.hunk_ranges")
  h.eq({ { start_line = 1, end_line = 5 } }, hunk_ranges)
end

T["Render"]["render_file_list()"] = function()
  child.lua([[
    local bufnr = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace("test_ns")
    local r = Render.new(bufnr, ns)
    local files = { "path/to/file.lua", "new_file.txt" }
    local by_file = {
      ["path/to/file.lua"] = { net_operation = "modified" },
      ["new_file.txt"] = { net_operation = "created" },
    }
    r:render_file_list(files, by_file, 1)
    _G.test_buf = bufnr
  ]])
  local lines = child.lua_get("api.nvim_buf_get_lines(_G.test_buf, 0, -1, false)")
  h.eq(2, #lines)
  -- The exact output depends on config icons, but we can check if it contains the filename
  h.expect_contains("file.lua", lines[1])
  h.expect_contains("path/to/", lines[1])
  h.expect_contains("new_file.txt", lines[2])
end

T["Render"]["render_diff() with word_diff"] = function()
  child.lua([[
    local bufnr = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace("test_ns")
    local r = Render.new(bufnr, ns)
    local hunks = {
      {
        original_start = 1, original_count = 1,
        updated_start = 1, updated_count = 1,
        context_before = {},
        removed_lines = { "old word" },
        added_lines = { "new word" },
        context_after = {},
      }
    }
    r:render_diff(hunks, true)
    _G.test_buf = bufnr
    _G.test_ns = ns
  ]])

  local marks = child.lua_get("api.nvim_buf_get_extmarks(_G.test_buf, _G.test_ns, 0, -1, { details = true })")
  local has_word_hl = false
  for _, mark in ipairs(marks) do
    if mark[4].hl_group == "FSMonitorDeleteWord" or mark[4].hl_group == "FSMonitorAddWord" then
      has_word_hl = true
      break
    end
  end
  h.expect_true(has_word_hl, "Should apply word highlights when word_diff is true")
end

T["Render"]["render_diff() empty hunks"] = function()
  child.lua([[
    local bufnr = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace("test_ns")
    local r = Render.new(bufnr, ns)
    r:render_diff({})
    _G.test_buf = bufnr
  ]])
  local lines = child.lua_get("api.nvim_buf_get_lines(_G.test_buf, 0, -1, false)")
  h.expect_contains("No differences detected", lines[2])
end

T["Render"]["render_file_list() with renamed file"] = function()
  child.lua([[
    local bufnr = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace("test_ns")
    local r = Render.new(bufnr, ns)
    local files = { "new_path.lua" }
    local by_file = {
      ["new_path.lua"] = { 
        net_operation = "renamed",
        old_path = "old_path.lua"
      }
    }
    r:render_file_list(files, by_file, 1)
    _G.test_buf = bufnr
  ]])
  local lines = child.lua_get("api.nvim_buf_get_lines(_G.test_buf, 0, -1, false)")
  h.expect_contains("new_path.lua ← old_path.lua", lines[1])
end

return T
