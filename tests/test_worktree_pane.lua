local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        fs_monitor = require("fs-monitor")
        fs_monitor.setup()

        _G.TEST_DIR = vim.fn.tempname()
        vim.fn.mkdir(_G.TEST_DIR, "p")
        vim.uv.chdir(_G.TEST_DIR)

        -- Initialize git repo
        vim.fn.system("git init")
        vim.fn.system("git config user.email 'test@example.com'")
        vim.fn.system("git config user.name 'Test User'")
        vim.fn.system("git commit --allow-empty -m 'Initial commit'")
      ]])
    end,
    post_case = function()
      child.lua([[
        _G.cleanup_done = false
        fs_monitor.clear_all(function()
          _G.cleanup_done = true
        end)
        vim.wait(2000, function() return _G.cleanup_done end)
        pcall(vim.fn.delete, _G.TEST_DIR, "rf")
      ]])
    end,
    post_once = child.stop,
  },
})

T["WorktreePane"] = new_set()

T["WorktreePane"]["module loads successfully"] = function()
  child.lua([[
    _G.loaded = false
    local ok, module = pcall(require, "fs-monitor.worktree_pane")
    _G.loaded = ok
  ]])

  local loaded = child.lua_get("_G.loaded")
  h.expect_true(loaded, "worktree_pane module should load successfully")
end

T["WorktreePane"]["rejects non-existent session"] = function()
  child.lua([[
    local worktree_pane = require("fs-monitor.worktree_pane")
    _G.error_msg = nil

    -- Mock vim.notify to capture error messages
    local original_notify = vim.notify
    vim.notify = function(msg, level, opts)
      if level == vim.log.levels.ERROR then
        _G.error_msg = msg
      end
      original_notify(msg, level, opts)
    end

    worktree_pane.show("non_existent_session")
  ]])

  -- Wait a moment for the notification
  child.wait(500)

  local error_msg = child.lua_get("_G.error_msg")
  h.expect_contains("not found", error_msg or "", "Error message should mention session not found")
end

T["WorktreePane"]["rejects session with no changes"] = function()
  child.lua([[
    local session = fs_monitor.create_session({ id = "empty_session" })
    _G.error_msg = nil

    -- Mock vim.notify to capture warning messages
    local original_notify = vim.notify
    vim.notify = function(msg, level, opts)
      if level == vim.log.levels.WARN then
        _G.error_msg = msg
      end
      original_notify(msg, level, opts)
    end

    local worktree_pane = require("fs-monitor.worktree_pane")
    worktree_pane.show("empty_session")
  ]])

  -- Wait a moment for the notification
  child.wait(500)

  local error_msg = child.lua_get("_G.error_msg")
  h.expect_contains("No changes", error_msg or "", "Warning should mention no changes")
end

T["WorktreePane"]["creates pane for valid session"] = function()
  child.lua([[
    -- Create test file
    local test_file = _G.TEST_DIR .. "/test.txt"
    vim.fn.writefile({"line 1"}, test_file)

    -- Create session and start monitoring
    local session = fs_monitor.create_session({ id = "test_session" })
    fs_monitor.start("test_session", _G.TEST_DIR)

    -- Manually add a change to session for testing
    local mon_session = fs_monitor.get_session("test_session")
    if mon_session and mon_session.monitor then
      table.insert(mon_session.monitor.changes, {
        path = "test.txt",
        kind = "modified",
        old_content = "line 1\n",
        new_content = "line 1\nline 2\n",
        timestamp = vim.uv.hrtime(),
      })
    end

    _G.pane_works = false

    local updated_session = fs_monitor.get_session("test_session")
    if updated_session and updated_session.monitor and #updated_session.monitor.changes > 0 then
      local worktree_pane = require("fs-monitor.worktree_pane")
      
      -- Test that show() works without erroring
      local ok, err = pcall(worktree_pane.show, "test_session")
      _G.pane_works = ok
      _G.error_msg = err
      
      -- Close any windows we created
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
        if ft == "fs-monitor-worktree" then
          vim.api.nvim_win_close(win, true)
        end
      end
    end
  ]])

  child.wait(500)

  local pane_works = child.lua_get("_G.pane_works")
  local error_msg = child.lua_get("_G.error_msg")

  if not pane_works and error_msg then print("Error: " .. tostring(error_msg)) end

  h.expect_true(pane_works, "Pane should be created for valid session")
end

T["WorktreePane"]["sets correct buffer options"] = function()
  child.lua([[
    -- Create test file
    local test_file = _G.TEST_DIR .. "/test.txt"
    vim.fn.writefile({"line 1"}, test_file)

    -- Create session and start monitoring
    local session = fs_monitor.create_session({ id = "test_session" })
    fs_monitor.start("test_session", _G.TEST_DIR)

    -- Manually add a change to session for testing
    local mon_session = fs_monitor.get_session("test_session")
    if mon_session and mon_session.monitor then
      table.insert(mon_session.monitor.changes, {
        path = "test.txt",
        kind = "modified",
        old_content = "line 1\n",
        new_content = "line 1\nline 2\n",
        timestamp = vim.uv.hrtime(),
      })
    end

    _G.buftype = nil
    _G.filetype = nil

    local updated_session = fs_monitor.get_session("test_session")
    if updated_session and updated_session.monitor and #updated_session.monitor.changes > 0 then
      local worktree_pane = require("fs-monitor.worktree_pane")
      worktree_pane.show("test_session")
      
      -- Find the worktree pane buffer
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
        if ft == "fs-monitor-worktree" then
          _G.buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
          _G.filetype = ft
          vim.api.nvim_win_close(win, true)
          break
        end
      end
    end
  ]])

  child.wait(500)

  local buftype = child.lua_get("_G.buftype")
  local filetype = child.lua_get("_G.filetype")

  h.eq(buftype, "nofile", "Buffer should be nofile type")
  h.eq(filetype, "fs-monitor-worktree", "Buffer should have correct filetype")
end

T["WorktreePane"]["displays files with checkboxes"] = function()
  child.lua([[
    -- Create test file
    local test_file = _G.TEST_DIR .. "/test.txt"
    vim.fn.writefile({"line 1"}, test_file)

    -- Create session and start monitoring
    local session = fs_monitor.create_session({ id = "test_session" })
    fs_monitor.start("test_session", _G.TEST_DIR)

    -- Manually add a change to session for testing
    local mon_session = fs_monitor.get_session("test_session")
    if mon_session and mon_session.monitor then
      table.insert(mon_session.monitor.changes, {
        path = "test.txt",
        kind = "modified",
        old_content = "line 1\n",
        new_content = "line 1\nline 2\n",
        timestamp = vim.uv.hrtime(),
      })
    end

    _G.buffer_content = nil

    local updated_session = fs_monitor.get_session("test_session")
    if updated_session and updated_session.monitor and #updated_session.monitor.changes > 0 then
      local worktree_pane = require("fs-monitor.worktree_pane")
      worktree_pane.show("test_session")
      
      -- Find the worktree pane buffer and get its content
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
        if ft == "fs-monitor-worktree" then
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          _G.buffer_content = table.concat(lines, "\n")
          vim.api.nvim_win_close(win, true)
          break
        end
      end
    end
  ]])

  child.wait(500)

  local buffer_content = child.lua_get("_G.buffer_content")

  h.expect_not_nil(buffer_content, "Buffer content should be captured")

  if buffer_content then
    h.expect_contains("Commit Message", buffer_content, "Should contain commit message section")
    h.expect_contains("Changed Files", buffer_content, "Should contain changed files section")
    h.expect_contains("[x]", buffer_content, "Should contain checked checkbox")
  end
end

T["WorktreePane"]["has keymaps for common actions"] = function()
  child.lua([[
    -- Create test file
    local test_file = _G.TEST_DIR .. "/test.txt"
    vim.fn.writefile({"line 1"}, test_file)

    -- Create session and start monitoring
    local session = fs_monitor.create_session({ id = "test_session" })
    fs_monitor.start("test_session", _G.TEST_DIR)

    -- Manually add a change to session for testing
    local mon_session = fs_monitor.get_session("test_session")
    if mon_session and mon_session.monitor then
      table.insert(mon_session.monitor.changes, {
        path = "test.txt",
        kind = "modified",
        old_content = "line 1\n",
        new_content = "line 1\nline 2\n",
        timestamp = vim.uv.hrtime(),
      })
    end

    _G.has_q_keymap = false
    _G.has_space_keymap = false
    _G.has_i_keymap = false

    local updated_session = fs_monitor.get_session("test_session")
    if updated_session and updated_session.monitor and #updated_session.monitor.changes > 0 then
      local worktree_pane = require("fs-monitor.worktree_pane")
      worktree_pane.show("test_session")
      
      -- Find the worktree pane buffer and check its keymaps
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
        if ft == "fs-monitor-worktree" then
          local keymaps = vim.api.nvim_buf_get_keymap(buf, 'n')
          for _, map in ipairs(keymaps) do
            if map.lhs == 'q' then _G.has_q_keymap = true end
            if map.lhs == ' ' then _G.has_space_keymap = true end
            if map.lhs == 'i' then _G.has_i_keymap = true end
          end
          vim.api.nvim_win_close(win, true)
          break
        end
      end
    end
  ]])

  child.wait(500)

  local has_q = child.lua_get("_G.has_q_keymap")
  local has_space = child.lua_get("_G.has_space_keymap")
  local has_i = child.lua_get("_G.has_i_keymap")

  h.expect_true(has_q, "Should have 'q' keymap for closing")
  h.expect_true(has_space, "Should have '<Space>' keymap for toggling")
  h.expect_true(has_i, "Should have 'i' keymap for editing commit message")
end

return T
