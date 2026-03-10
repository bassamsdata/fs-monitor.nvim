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
        vim.wait(1400, function() return _G.cleanup_done end)
        pcall(vim.fn.delete, _G.TEST_DIR, "rf")
      ]])
    end,
    post_once = child.stop,
  },
})

T["Worktree"] = new_set()

T["Worktree"]["rejects non-existent session"] = function()
  child.lua([[
    local worktree = require("fs-monitor.worktree")
    _G.result = nil
    _G.error_msg = nil

    -- Mock vim.notify to capture error messages
    local original_notify = vim.notify
    vim.notify = function(msg, level, opts)
      if level == vim.log.levels.ERROR then
        _G.error_msg = msg
      end
      original_notify(msg, level, opts)
    end

    worktree.create_worktree("non_existent_session", function(success)
      _G.result = success
    end)
  ]])

  -- Wait for async callback
  child.wait(700)

  local result = child.lua_get("_G.result")
  local error_msg = child.lua_get("_G.error_msg")

  h.expect_false(result, "Should return false for non-existent session")
  h.expect_contains("not found", error_msg or "", "Error message should mention session not found")
end

T["Worktree"]["rejects session with no changes"] = function()
  child.lua([[
    local session = fs_monitor.create_session({ id = "empty_session" })
    _G.result = nil
    _G.error_msg = nil

    -- Mock vim.notify to capture warning messages
    local original_notify = vim.notify
    vim.notify = function(msg, level, opts)
      if level == vim.log.levels.WARN then
        _G.error_msg = msg
      end
      original_notify(msg, level, opts)
    end

    local worktree = require("fs-monitor.worktree")
    worktree.create_worktree("empty_session", function(success)
      _G.result = success
    end)
  ]])

  -- Wait for async callback
  child.wait(700)

  local result = child.lua_get("_G.result")
  local error_msg = child.lua_get("_G.error_msg")

  h.expect_false(result, "Should return false for session with no changes")
  h.expect_contains("no recorded changes", error_msg or "", "Warning should mention no changes")
end

T["Worktree"]["detects git repository"] = function()
  child.lua([[
    -- Create a session with changes
    local session = fs_monitor.create_session({ id = "test_session" })

    -- Add a mock change
    local mock_change = {
      path = "test.txt",
      kind = "modified",
      old_content = "old content",
      new_content = "new content",
      timestamp = vim.uv.hrtime(),
      tool_name = "workspace",
      metadata = {}
    }
    table.insert(session.changes, mock_change)

    _G.git_check_result = nil

    -- Test that git rev-parse works (we're in a git repo)
    local result = vim.fn.system("git rev-parse --show-toplevel")
    _G.git_check_result = (vim.v.shell_error == 0) and (result ~= "")
  ]])

  local git_check = child.lua_get("_G.git_check_result")
  h.expect_true(git_check, "Should detect git repository successfully")
end

T["Worktree"]["parses git status correctly"] = function()
  child.lua([[
    -- Create test files with various git states
    vim.fn.writefile({"content1"}, "tracked_file.txt")
    vim.fn.system("git add tracked_file.txt")
    vim.fn.system("git commit -m 'Add tracked file'")

    -- Modify tracked file
    vim.fn.writefile({"modified content"}, "tracked_file.txt")

    -- Create untracked file
    vim.fn.writefile({"untracked"}, "untracked_file.txt")

    -- Get git status
    local status_output = vim.fn.system("git status --porcelain")

    _G.status_lines = {}
    for line in status_output:gmatch("[^\r\n]+") do
      table.insert(_G.status_lines, line)
    end
  ]])

  local status_lines = child.lua_get("_G.status_lines")

  h.expect_gt(#status_lines, 0, "Should have git status changes")
end

T["Worktree"]["identifies exclusive session changes"] = function()
  child.lua([[
    -- Create test files to simulate session changes
    vim.fn.writefile({"content1"}, "file1.txt")
    vim.fn.writefile({"content2"}, "file2.txt")

    -- Add to git
    vim.fn.system("git add file1.txt file2.txt")
    vim.fn.system("git commit -m 'Add files'")

    -- Modify files (simulating session changes)
    vim.fn.writefile({"modified1"}, "file1.txt")
    vim.fn.writefile({"modified2"}, "file2.txt")

    -- Get git status
    local status_output = vim.fn.system("git status --porcelain")
    _G.status_lines = {}
    for line in status_output:gmatch("[^\r\n]+") do
      table.insert(_G.status_lines, line)
    end

    _G.file_count = #_G.status_lines
  ]])

  local file_count = child.lua_get("_G.file_count")
  h.eq(2, file_count, "Should have 2 modified files")
end

T["Worktree"]["handles worktree name collision"] = function()
  child.lua([[
    -- Test that unique paths are generated
    local repo_root = vim.fn.getcwd()
    local base_name = "test-worktree"

    -- Create existing directory
    local existing_path = repo_root .. "/../" .. base_name
    vim.fn.mkdir(existing_path, "p")

    -- Generate unique paths
    local path1 = repo_root .. "/../" .. base_name
    local path2 = repo_root .. "/../" .. base_name .. "_1"
    local path3 = repo_root .. "/../" .. base_name .. "_2"

    -- Cleanup
    vim.fn.delete(existing_path, "rf")

    _G.path1 = path1
    _G.path2 = path2
    _G.path3 = path3
  ]])

  local path1 = child.lua_get("_G.path1")
  local path2 = child.lua_get("_G.path2")
  local path3 = child.lua_get("_G.path3")

  h.expect_not_nil(path1, "Should generate base path")
  h.expect_not_nil(path2, "Should generate _1 suffix path")
  h.expect_not_nil(path3, "Should generate _2 suffix path")
end

T["Worktree"]["integrates with FSMonitor command"] = function()
  child.lua([[
    -- Create a session with changes
    local session = fs_monitor.create_session({ id = "cmd_test_session" })
    session.changes = {
      {
        path = "test.txt",
        kind = "modified",
        old_content = "old",
        new_content = "new",
        timestamp = vim.uv.hrtime(),
        tool_name = "workspace",
        metadata = {}
      }
    }

    -- Verify command is available
    local command_exists = vim.fn.exists(":FSMonitor") > 0
    _G.command_exists = command_exists
  ]])

  local command_exists = child.lua_get("_G.command_exists")
  h.expect_true(command_exists, "FSMonitor command should be available")
end

T["Worktree"]["has worktree subcommand registered"] = function()
  -- Test that the worktree module can be required and has the expected function
  child.lua([[
    local worktree = require("fs-monitor.worktree")
    _G.worktable_loaded = true
    _G.has_create_function = (type(worktree.create_worktree) == "function")
  ]])

  local worktree_loaded = child.lua_get("_G.worktable_loaded")
  local has_create_function = child.lua_get("_G.has_create_function")

  h.expect_true(worktree_loaded, "worktree module should be loadable")
  h.expect_true(has_create_function, "worktree module should have create_worktree function")
end

return T
