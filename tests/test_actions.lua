local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        Viewer = require("fs-monitor.viewer.viewer")
        _G.api = vim.api

        -- Helper to create a basic viewer for testing
        _G.create_test_viewer = function()
          local changes = {
            {
              path = "test1.lua",
              kind = "modified",
              old_content = "line1\nline2",
              new_content = "line1\nmodified",
              timestamp = 100,
              tool_name = "test",
              metadata = {},
            },
            {
              path = "test2.lua",
              kind = "created",
              new_content = "new file",
              timestamp = 200,
              tool_name = "test",
              metadata = {},
            },
          }

          local checkpoints = { { timestamp = 150, label = "CP1", cycle = 1 } }

          return Viewer.new(changes, checkpoints, {})
        end
      ]])
    end,
    post_case = function()
      child.lua([[
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
          end
        end
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_is_valid(win) then
            local config = vim.api.nvim_win_get_config(win)
            if config.relative ~= "" then
              pcall(vim.api.nvim_win_close, win, true)
            end
          end
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["Actions"] = new_set()

T["Actions"]["next_file()"] = function()
  child.lua([[
    _G.viewer = _G.create_test_viewer()
    _G.viewer:show()

    local initial_idx = _G.viewer.selected_file_idx
    _G.viewer:next_file()
    _G.final_idx = _G.viewer.selected_file_idx
  ]])

  h.eq(1, child.lua_get("_G.initial_idx or 1"))
  h.eq(2, child.lua_get("_G.final_idx"))
end

T["Actions"]["prev_file()"] = function()
  child.lua([[
    _G.viewer = _G.create_test_viewer()
    _G.viewer:show()

    _G.viewer:next_file() -- Move to file 2
    _G.before_prev = _G.viewer.selected_file_idx
    _G.viewer:prev_file() -- Move back to file 1
    _G.after_prev = _G.viewer.selected_file_idx
  ]])

  h.eq(2, child.lua_get("_G.before_prev"))
  h.eq(1, child.lua_get("_G.after_prev"))
end

T["Actions"]["next_hunk() and prev_hunk()"] = function()
  child.lua([[
    local changes = {
      {
        path = "test1.lua",
        kind = "modified",
        old_content = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10",
        new_content = "1\nmod\n3\n4\n5\n6\n7\nmod2\n9\n10",
        timestamp = 100,
        tool_name = "test",
        metadata = {},
      },
    }

    _G.viewer = Viewer.new(changes, {}, {})
    _G.viewer:show()

    api.nvim_set_current_win(_G.viewer.right_win)
    api.nvim_win_set_cursor(_G.viewer.right_win, {1, 0})

    _G.viewer:next_hunk()
    _G.pos1 = api.nvim_win_get_cursor(_G.viewer.right_win)

    _G.viewer:next_hunk()
    _G.pos2 = api.nvim_win_get_cursor(_G.viewer.right_win)

    _G.viewer:prev_hunk()
    _G.pos3 = api.nvim_win_get_cursor(_G.viewer.right_win)
  ]])

  local pos1 = child.lua_get("_G.pos1")
  local pos2 = child.lua_get("_G.pos2")

  h.expect_gt(pos1[1], 1)
  h.expect_gt(pos2[1], 1)
end

T["Actions"]["revert_current_hunk()"] = function()
  child.lua([[
    local test_file = "revert_test.txt"
    local cwd = vim.uv.cwd()
    local absolute_path = cwd .. "/" .. test_file

    vim.fn.writefile({"line1", "modified", "line3"}, absolute_path)

    local changes = {
      {
        path = test_file,
        kind = "modified",
        old_content = "line1\noriginal\nline3",
        new_content = "line1\nmodified\nline3",
        timestamp = 100,
        tool_name = "test",
        metadata = {},
      },
    }

    _G.viewer = Viewer.new(changes, {}, { fs_monitor = { changes = {} } })
    _G.viewer:show()

    require("fs-monitor.utils.ui").confirm = function() return 1 end

    local lines = api.nvim_buf_get_lines(_G.viewer.right_buf, 0, -1, false)
    local target_line = 1
    for i, line in ipairs(lines) do
      if line:find("modified") then
        target_line = i
        break
      end
    end
    api.nvim_win_set_cursor(_G.viewer.right_win, {target_line, 0})

    _G.viewer:revert_current_hunk()

    _G.reverted_content = vim.fn.readfile(absolute_path)
    os.remove(absolute_path)
  ]])

  local content = child.lua_get("_G.reverted_content")
  h.eq({ "line1", "original", "line3" }, content)
end

T["Actions"]["reset_checkpoint_filter()"] = function()
  child.lua([[
    local all_changes = {
      { path = "file1", kind = "modified", timestamp = 100, tool_name = "test", metadata = {} },
      { path = "file2", kind = "modified", timestamp = 200, tool_name = "test", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 150, label = "CP1", cycle = 1 },
    }

    _G.viewer = Viewer.new(all_changes, checkpoints, {})
    _G.viewer:show()

    _G.viewer:apply_checkpoint_filter(1, "cumulative")
    _G.filtered_count = #_G.viewer.filtered_changes

    _G.viewer:reset_checkpoint_filter()
    _G.reset_count = #_G.viewer.filtered_changes
    _G.checkpoint_idx = _G.viewer.selected_checkpoint_idx
  ]])

  h.eq(1, child.lua_get("_G.filtered_count"))
  h.eq(2, child.lua_get("_G.reset_count"))
  h.eq(vim.NIL, child.lua_get("_G.checkpoint_idx"))
end

return T
