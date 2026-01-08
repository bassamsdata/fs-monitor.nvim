local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        Actions = require("fs-monitor.diff.actions")
        _G.api = vim.api
        
        -- Mock state object
        _G.create_mock_state = function()
          local files_buf = api.nvim_create_buf(false, true)
          local checkpoints_buf = api.nvim_create_buf(false, true)
          local right_buf = api.nvim_create_buf(false, true)
          
          local files_win = api.nvim_open_win(files_buf, false, {relative='editor', row=0, col=0, width=10, height=10})
          local checkpoints_win = api.nvim_open_win(checkpoints_buf, false, {relative='editor', row=11, col=0, width=10, height=10})
          local right_win = api.nvim_open_win(right_buf, false, {relative='editor', row=0, col=11, width=20, height=21})

          return {
            files_buf = files_buf,
            checkpoints_buf = checkpoints_buf,
            right_buf = right_buf,
            files_win = files_win,
            checkpoints_win = checkpoints_win,
            right_win = right_win,
            ns = api.nvim_create_namespace("test_ns"),
            selected_file_idx = 1,
            word_diff = false,
            summary = {
              files = { "test1.lua", "test2.lua" },
              by_file = {
                ["test1.lua"] = {
                  net_operation = "modified",
                  changes = {
                    { old_content = "line1\nline2", new_content = "line1\nmodified" }
                  }
                },
                ["test2.lua"] = {
                  net_operation = "created",
                  changes = {
                    { new_content = "new file" }
                  }
                }
              }
            },
            checkpoints = { { timestamp = 100, label = "CP1" } },
            all_changes = {},
            get_geometry = function() return {} end,
            generate_summary = function(changes) return { files = {}, by_file = {} } end
          }
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
      ]])
    end,
    post_once = child.stop,
  },
})

T["Actions"] = new_set()

T["Actions"]["update_preview()"] = function()
  child.lua([[
    _G.state = _G.create_mock_state()
    Actions.update_preview(_G.state, 1)
  ]])
  local lines = child.lua_get("api.nvim_buf_get_lines(_G.state.right_buf, 0, -1, false)")
  h.expect_gt(#lines, 0)
  h.expect_contains("line1", lines[2])
  h.eq("test1.lua", child.lua_get("_G.state.current_filepath"))
end

T["Actions"]["navigate_files()"] = function()
  child.lua([[
    _G.state = _G.create_mock_state()
    Actions.navigate_files(_G.state, 1) -- move to test2.lua
  ]])
  h.eq(2, child.lua_get("_G.state.selected_file_idx"))
  h.eq("test2.lua", child.lua_get("_G.state.current_filepath"))

  child.lua([[
    Actions.navigate_files(_G.state, -1) -- move back to test1.lua
  ]])
  h.eq(1, child.lua_get("_G.state.selected_file_idx"))
  h.eq("test1.lua", child.lua_get("_G.state.current_filepath"))
end

T["Actions"]["jump_next_hunk() and jump_prev_hunk()"] = function()
  child.lua([[
    _G.state = _G.create_mock_state()
    -- Multiple hunks
    _G.state.summary.by_file["test1.lua"].changes[1].old_content = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10"
    _G.state.summary.by_file["test1.lua"].changes[1].new_content = "1\nmod\n3\n4\n5\n6\n7\nmod2\n9\n10"
    Actions.update_preview(_G.state, 1)
    
    api.nvim_set_current_win(_G.state.right_win)
    api.nvim_win_set_cursor(_G.state.right_win, {1, 0})
    
    Actions.jump_next_hunk(_G.state)
    _G.pos1 = api.nvim_win_get_cursor(_G.state.right_win)
    
    Actions.jump_next_hunk(_G.state)
    _G.pos2 = api.nvim_win_get_cursor(_G.state.right_win)
    
    Actions.jump_prev_hunk(_G.state)
    _G.pos3 = api.nvim_win_get_cursor(_G.state.right_win)
  ]])

  local pos1 = child.lua_get("_G.pos1")
  local pos2 = child.lua_get("_G.pos2")

  -- Expectation: just move to a different line for now to ensure it functions
  h.expect_gt(pos1[1], 1)
  h.expect_gt(pos2[1], 1)
end

T["Actions"]["revert_current_hunk()"] = function()
  child.lua([[
    _G.state = _G.create_mock_state()
    
    local test_file = "revert_test.txt"
    -- Use uv.cwd() to ensure we know where we are
    local cwd = vim.uv.cwd()
    local absolute_path = cwd .. "/" .. test_file
    
    vim.fn.writefile({"line1", "modified", "line3"}, absolute_path)
    
    _G.state.current_filepath = test_file
    _G.state.summary.files = { test_file }
    _G.state.summary.by_file[test_file] = {
      net_operation = "modified",
      changes = {
        { old_content = "line1\noriginal\nline3", new_content = "line1\nmodified\nline3" }
      }
    }
    
    -- Mock FSMonitor and UI
    _G.state.fs_monitor = { changes = {} }
    _G.state.generate_summary = function() return _G.state.summary end
    
    require("fs-monitor.utils.ui").confirm = function() return 1 end -- Auto-confirm
    
    Actions.update_preview(_G.state, 1)
    
    -- Find the line with "modified" in the right buffer
    local lines = api.nvim_buf_get_lines(_G.state.right_buf, 0, -1, false)
    local target_line = 1
    for i, line in ipairs(lines) do
      if line:find("modified") then
        target_line = i
        break
      end
    end
    api.nvim_win_set_cursor(_G.state.right_win, {target_line, 0})
    
    Actions.revert_current_hunk(_G.state)
    
    _G.reverted_content = vim.fn.readfile(absolute_path)
    os.remove(absolute_path)
  ]])

  local content = child.lua_get("_G.reverted_content")
  h.eq({ "line1", "original", "line3" }, content)
end

T["Actions"]["reset_checkpoint_filter()"] = function()
  child.lua([[
    _G.state = _G.create_mock_state()

    -- Setup initial "filtered" state
    _G.state.selected_checkpoint_idx = 1
    _G.state.all_changes = { { path = "file1" }, { path = "file2" } }
    _G.state.filtered_changes = { { path = "file1" } }
    _G.state.selected_file_idx = 2

    -- Mock render to avoid UI complexity
    package.loaded["fs-monitor.diff.render"] = {
      new = function()
        return {
          render_file_list = function() end,
          render_checkpoints = function() end,
          render_diff = function() return {}, {}, {} end
        }
      end
    }

    Actions.reset_checkpoint_filter(_G.state)

    -- Cleanup mock
    package.loaded["fs-monitor.diff.render"] = nil
  ]])

  h.eq(vim.NIL, child.lua_get("_G.state.selected_checkpoint_idx"))
  -- Using deep equal check via lua_get returning tables
  local filtered = child.lua_get("_G.state.filtered_changes")
  local all = child.lua_get("_G.state.all_changes")
  h.eq(all, filtered)
  h.eq(2, #filtered)
  h.eq(1, child.lua_get("_G.state.selected_file_idx"))
end

return T
