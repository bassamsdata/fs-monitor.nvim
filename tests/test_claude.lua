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
        claude = require("fs-monitor.providers.claude")

        _G.TEST_DIR = vim.fn.tempname()
        vim.fn.mkdir(_G.TEST_DIR, "p")
        _G.TEST_DIR = vim.uv.fs_realpath(_G.TEST_DIR)
        vim.uv.chdir(_G.TEST_DIR)

        -- MOCKS: stub hook installation (avoids real FS writes to .claude/)
        claude._original_install_hooks = claude.install_hooks
        claude.install_hooks = function(_, on_done)
          claude._hooks_installed = true
          if on_done then on_done(true) end
        end

        claude._original_uninstall_hooks = claude.uninstall_hooks
        claude.uninstall_hooks = function(_, on_done)
          claude._hooks_installed = false
          if on_done then on_done() end
        end
      ]])
    end,
    post_case = function()
      child.lua([[
        if claude._session_id then
          pcall(function()
            claude.stop({ uninstall_hooks = false })
          end)
        end
        _G.cleanup_done = false
        fs_monitor.clear_all(function()
          _G.cleanup_done = true
        end)
        vim.wait(1000, function() return _G.cleanup_done end)
        pcall(vim.fn.delete, _G.TEST_DIR, "rf")
      ]])
    end,
    post_once = child.stop,
  },
})

-- ============================================================================
-- Session Lifecycle
-- ============================================================================

T["Session"] = new_set()

T["Session"]["start creates a session"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(500)

  child.lua([[
    _G.session_id = claude._session_id
    _G.is_active = claude.is_active()
    _G.cycle = claude._cycle
    _G.watcher_active = claude._watcher_active
  ]])

  h.expect_not_nil(child.lua_get("_G.session_id"), "Session ID should be set")
  h.eq(true, child.lua_get("_G.is_active"))
  h.eq(0, child.lua_get("_G.cycle"))
  h.eq(false, child.lua_get("_G.watcher_active"))
end

T["Session"]["start warns on duplicate session"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    _G.first_session = claude._session_id
    claude.start({ install_hooks = false })
    _G.second_session = claude._session_id
  ]])

  child.wait(300)

  h.eq(child.lua_get("_G.first_session"), child.lua_get("_G.second_session"))
end

T["Session"]["stop destroys session"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    claude.stop({ uninstall_hooks = false })
    _G.session_id = claude._session_id
    _G.is_active = claude.is_active()
  ]])

  h.eq(vim.NIL, child.lua_get("_G.session_id"))
  h.eq(false, child.lua_get("_G.is_active"))
end

T["Session"]["stop resets cycle counter and watcher state"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    claude._cycle = 5
    claude._watcher_active = true
    claude.stop({ uninstall_hooks = false })
    _G.cycle = claude._cycle
    _G.watcher = claude._watcher_active
  ]])

  h.eq(0, child.lua_get("_G.cycle"))
  h.eq(false, child.lua_get("_G.watcher"))
end

T["Session"]["get_session_id returns active id"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    _G.getter_id = claude.get_session_id()
    _G.field_id = claude._session_id
  ]])

  h.eq(child.lua_get("_G.getter_id"), child.lua_get("_G.field_id"))
end

-- ============================================================================
-- PreToolUse: activates the FS watcher
-- ============================================================================

T["PreToolUse"] = new_set()

T["PreToolUse"]["activates watcher on first tool"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    _G.watcher_before = claude._watcher_active
    claude._on_pre_tool_use("Write")
    _G.watcher_after = claude._watcher_active
  ]])

  h.eq(false, child.lua_get("_G.watcher_before"))
  h.eq(true, child.lua_get("_G.watcher_after"))
end

T["PreToolUse"]["second pre_tool_use is a no-op when watcher already active"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    claude._on_pre_tool_use("Write")
    _G.watcher_1 = claude._watcher_active
    claude._on_pre_tool_use("Edit")
    _G.watcher_2 = claude._watcher_active
  ]])

  h.eq(true, child.lua_get("_G.watcher_1"))
  h.eq(true, child.lua_get("_G.watcher_2"))
end

T["PreToolUse"]["noop without session"] = function()
  child.lua([[
    _G.result = claude._on_pre_tool_use("Write")
    _G.watcher = claude._watcher_active
  ]])

  h.eq("", child.lua_get("_G.result"))
  h.eq(false, child.lua_get("_G.watcher"))
end

-- ============================================================================
-- PostToolUse (_on_file_changed): deactivates watcher + registers file
-- ============================================================================

T["PostToolUse"] = new_set()

T["PostToolUse"]["deactivates watcher and registers file change"] = function()
  child.lua([[
    local path = vim.fs.joinpath(_G.TEST_DIR, "written.txt")
    local f = io.open(path, "w")
    f:write("original")
    f:close()

    claude.start({ install_hooks = false })
  ]])

  child.wait(500)

  child.lua([[
    claude._on_pre_tool_use("Write")
    _G.watcher_during = claude._watcher_active

    local path = vim.fs.joinpath(_G.TEST_DIR, "written.txt")
    local f = io.open(path, "w")
    f:write("modified by claude")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "written.txt"), "Write")
    _G.watcher_after = claude._watcher_active
  ]])

  child.wait(500)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes
    if #changes > 0 then
      _G.last_kind = changes[#changes].kind
      _G.last_content = changes[#changes].new_content
    end
  ]])

  h.eq(true, child.lua_get("_G.watcher_during"))
  h.eq(false, child.lua_get("_G.watcher_after"))
  h.expect_gte(child.lua_get("_G.change_count"), 1, "Should register a change")
end

T["PostToolUse"]["handles empty file_path (Bash tool)"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    claude._on_pre_tool_use("Bash")
    _G.watcher_during = claude._watcher_active
    claude._on_file_changed("", "Bash")
    _G.watcher_after = claude._watcher_active
  ]])

  h.eq(true, child.lua_get("_G.watcher_during"))
  h.eq(false, child.lua_get("_G.watcher_after"))
end

T["PostToolUse"]["noop without session"] = function()
  child.lua([[
    _G.result = claude._on_file_changed("/some/file.txt", "Write")
  ]])

  h.eq("", child.lua_get("_G.result"))
end

-- ============================================================================
-- SessionEnd: checkpoint + baseline refresh
-- ============================================================================

T["SessionEnd"] = new_set()

T["SessionEnd"]["creates checkpoint on session end"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    claude._on_pre_tool_use("Write")
    local path = vim.fs.joinpath(_G.TEST_DIR, "checkpoint_test.txt")
    local f = io.open(path, "w")
    f:write("checkpoint data")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "checkpoint_test.txt"), "Write")
  ]])

  child.wait(300)

  child.lua([[
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = claude.get_session_id()
    local checkpoints = fs_monitor.get_checkpoints(session_id)
    _G.checkpoint_count = #checkpoints
    if #checkpoints > 0 then
      _G.checkpoint_label = checkpoints[1].label
    end
  ]])

  h.expect_gte(child.lua_get("_G.checkpoint_count"), 1, "Should create a checkpoint")
  h.eq("Response #1", child.lua_get("_G.checkpoint_label"))
end

T["SessionEnd"]["increments cycle counter"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    _G.cycle_before = claude._cycle

    claude._on_pre_tool_use("Write")
    local f = io.open(vim.fs.joinpath(_G.TEST_DIR, "cycle1.txt"), "w")
    f:write("cycle 1")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "cycle1.txt"), "Write")
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    _G.cycle_after_1 = claude._cycle

    claude._on_pre_tool_use("Write")
    local f = io.open(vim.fs.joinpath(_G.TEST_DIR, "cycle2.txt"), "w")
    f:write("cycle 2")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "cycle2.txt"), "Write")
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    _G.cycle_after_2 = claude._cycle
  ]])

  h.eq(0, child.lua_get("_G.cycle_before"))
  h.eq(1, child.lua_get("_G.cycle_after_1"))
  h.eq(2, child.lua_get("_G.cycle_after_2"))
end

T["SessionEnd"]["deactivates watcher if still active"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    claude._on_pre_tool_use("Bash")
    _G.watcher_during = claude._watcher_active
    claude._on_session_end()
    _G.watcher_after = claude._watcher_active
  ]])

  child.wait(300)

  h.eq(true, child.lua_get("_G.watcher_during"))
  h.eq(false, child.lua_get("_G.watcher_after"))
end

T["SessionEnd"]["noop without session"] = function()
  child.lua([[
    _G.result = claude._on_session_end()
  ]])

  h.eq("", child.lua_get("_G.result"))
end

T["SessionEnd"]["skips checkpoint when no new changes since last"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  -- First end with a change -> checkpoint
  child.lua([[
    claude._on_pre_tool_use("Write")
    local f = io.open(vim.fs.joinpath(_G.TEST_DIR, "once.txt"), "w")
    f:write("data")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "once.txt"), "Write")
    claude._on_session_end()
  ]])

  child.wait(800)

  -- Second end with NO new changes -> no additional checkpoint
  child.lua([[
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = claude.get_session_id()
    local checkpoints = fs_monitor.get_checkpoints(session_id)
    _G.checkpoint_count = #checkpoints
  ]])

  h.eq(1, child.lua_get("_G.checkpoint_count"))
end

-- ============================================================================
-- SessionStart: auto-start support
-- ============================================================================

T["SessionStart"] = new_set()

T["SessionStart"]["noop when session already exists"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    _G.session_before = claude._session_id
    claude._on_session_start()
    _G.session_after = claude._session_id
  ]])

  h.eq(child.lua_get("_G.session_before"), child.lua_get("_G.session_after"))
end

T["SessionStart"]["auto-starts when vim.g.fs_monitor_claude_auto is set"] = function()
  child.lua([[
    vim.g.fs_monitor_claude_auto = true
    claude._on_session_start()
  ]])

  child.wait(500)

  child.lua([[
    _G.session_id = claude._session_id
    _G.is_active = claude.is_active()
    vim.g.fs_monitor_claude_auto = nil
  ]])

  h.expect_not_nil(child.lua_get("_G.session_id"), "Session should auto-start")
  h.eq(true, child.lua_get("_G.is_active"))
end

T["SessionStart"]["does not auto-start without flag"] = function()
  child.lua([[
    vim.g.fs_monitor_claude_auto = nil
    claude._on_session_start()
    _G.session_id = claude._session_id
    _G.is_active = claude.is_active()
  ]])

  h.eq(vim.NIL, child.lua_get("_G.session_id"))
  h.eq(false, child.lua_get("_G.is_active"))
end

-- ============================================================================
-- Write Tool: file creation + modification via watcher
-- ============================================================================

T["WriteTool"] = new_set()

T["WriteTool"]["detects file creation via watcher"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    claude._on_pre_tool_use("Write")

    local path = vim.fs.joinpath(_G.TEST_DIR, "created.txt")
    local f = io.open(path, "w")
    f:write("hello world")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "created.txt"), "Write")
  ]])

  child.wait(300)

  child.lua([[
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes
    if #changes > 0 then
      _G.first_path = changes[1].path
      _G.first_kind = changes[1].kind
      _G.first_content = changes[1].new_content
    end
  ]])

  h.expect_gte(child.lua_get("_G.change_count"), 1, "Should detect at least 1 change")
  h.eq("created.txt", child.lua_get("_G.first_path"))
  h.eq("created", child.lua_get("_G.first_kind"))
  h.eq("hello world", child.lua_get("_G.first_content"))
end

T["WriteTool"]["detects file modification via watcher"] = function()
  child.lua([[
    local path = vim.fs.joinpath(_G.TEST_DIR, "existing.txt")
    local f = io.open(path, "w")
    f:write("original content")
    f:close()

    claude.start({ install_hooks = false })
  ]])

  child.wait(500)

  child.lua([[
    claude._on_pre_tool_use("Edit")

    local path = vim.fs.joinpath(_G.TEST_DIR, "existing.txt")
    local f = io.open(path, "w")
    f:write("modified content")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "existing.txt"), "Edit")
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes
    if #changes > 0 then
      _G.first_kind = changes[1].kind
      _G.old_content = changes[1].old_content
      _G.new_content = changes[1].new_content
    end
  ]])

  h.expect_gte(child.lua_get("_G.change_count"), 1, "Should detect at least 1 change")
  h.eq("modified", child.lua_get("_G.first_kind"))
  h.eq("original content", child.lua_get("_G.old_content"))
  h.eq("modified content", child.lua_get("_G.new_content"))
end

-- ============================================================================
-- Bash Tool: watcher catches changes even without file_path
-- ============================================================================

T["BashTool"] = new_set()

T["BashTool"]["detects file creation from bash tool"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    claude._on_pre_tool_use("Bash")

    local path = vim.fs.joinpath(_G.TEST_DIR, "bash_created.txt")
    local f = io.open(path, "w")
    f:write("created by bash")
    f:close()
  ]])

  child.wait(500)

  -- Bash posts empty file_path
  child.lua([[
    claude._on_file_changed("", "Bash")
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes
    if #changes > 0 then
      _G.first_path = changes[1].path
      _G.first_kind = changes[1].kind
    end
  ]])

  h.expect_gte(child.lua_get("_G.change_count"), 1, "Bash file creation should be detected")
  h.eq("bash_created.txt", child.lua_get("_G.first_path"))
  h.eq("created", child.lua_get("_G.first_kind"))
end

T["BashTool"]["detects file rename (mv) from bash tool"] = function()
  child.lua([[
    local path = vim.fs.joinpath(_G.TEST_DIR, "before_mv.txt")
    local f = io.open(path, "w")
    f:write("will be renamed")
    f:close()

    claude.start({ install_hooks = false })
  ]])

  child.wait(500)

  child.lua([[
    claude._on_pre_tool_use("Bash")

    local src = vim.fs.joinpath(_G.TEST_DIR, "before_mv.txt")
    local dst = vim.fs.joinpath(_G.TEST_DIR, "after_mv.txt")
    os.rename(src, dst)
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed("", "Bash")
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes

    _G.has_renamed = false
    _G.has_deleted = false
    _G.has_created = false
    for _, c in ipairs(changes) do
      if c.kind == "renamed" then _G.has_renamed = true end
      if c.kind == "deleted" and c.path == "before_mv.txt" then _G.has_deleted = true end
      if c.kind == "created" and c.path == "after_mv.txt" then _G.has_created = true end
    end
  ]])

  h.expect_gte(child.lua_get("_G.change_count"), 1, "mv should produce changes")
  local has_renamed = child.lua_get("_G.has_renamed")
  local has_deleted = child.lua_get("_G.has_deleted")
  local has_created = child.lua_get("_G.has_created")
  h.expect_true(has_renamed or (has_deleted and has_created), "mv should produce renamed event or deleted+created pair")
end

T["BashTool"]["detects file deletion from bash tool"] = function()
  child.lua([[
    local path = vim.fs.joinpath(_G.TEST_DIR, "to_delete.txt")
    local f = io.open(path, "w")
    f:write("will be deleted")
    f:close()

    claude.start({ install_hooks = false })
  ]])

  child.wait(500)

  child.lua([[
    claude._on_pre_tool_use("Bash")

    local path = vim.fs.joinpath(_G.TEST_DIR, "to_delete.txt")
    os.remove(path)
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed("", "Bash")
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes
    if #changes > 0 then
      _G.last_path = changes[#changes].path
      _G.last_kind = changes[#changes].kind
    end
  ]])

  h.expect_gte(child.lua_get("_G.change_count"), 1, "rm should be detected")
  h.eq("to_delete.txt", child.lua_get("_G.last_path"))
  h.eq("deleted", child.lua_get("_G.last_kind"))
end

-- ============================================================================
-- Guards: noop without session
-- ============================================================================

T["Guards"] = new_set()

T["Guards"]["pre_tool_use noop without session"] = function()
  child.lua([[
    _G.result = claude._on_pre_tool_use("Write")
    _G.watcher = claude._watcher_active
  ]])

  h.eq("", child.lua_get("_G.result"))
  h.eq(false, child.lua_get("_G.watcher"))
end

T["Guards"]["file_changed noop without session"] = function()
  child.lua([[
    _G.result = claude._on_file_changed("/some/file.txt", "Write")
  ]])

  h.eq("", child.lua_get("_G.result"))
end

T["Guards"]["session_end noop without session"] = function()
  child.lua([[
    _G.result = claude._on_session_end()
  ]])

  h.eq("", child.lua_get("_G.result"))
end

T["Guards"]["session_start noop without auto flag"] = function()
  child.lua([[
    _G.result = claude._on_session_start()
  ]])

  h.eq("", child.lua_get("_G.result"))
end

-- ============================================================================
-- Full Workflow: multi-response session
-- ============================================================================

T["Workflow"] = new_set()

T["Workflow"]["full multi-tool response cycle"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  -- Response 1: Write a file
  child.lua([[
    claude._on_pre_tool_use("Write")
    local f = io.open(vim.fs.joinpath(_G.TEST_DIR, "response1.txt"), "w")
    f:write("first response")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "response1.txt"), "Write")
    claude._on_session_end()
  ]])

  child.wait(500)

  -- Response 2: Bash mv
  child.lua([[
    claude._on_pre_tool_use("Bash")
    os.rename(
      vim.fs.joinpath(_G.TEST_DIR, "response1.txt"),
      vim.fs.joinpath(_G.TEST_DIR, "renamed.txt")
    )
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed("", "Bash")
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    local checkpoints = fs_monitor.get_checkpoints(session_id)
    _G.total_changes = #changes
    _G.total_checkpoints = #checkpoints
    _G.cycle = claude._cycle
  ]])

  h.expect_gte(child.lua_get("_G.total_changes"), 2, "Should have changes from both responses")
  h.eq(2, child.lua_get("_G.total_checkpoints"))
  h.eq(2, child.lua_get("_G.cycle"))
end

T["Workflow"]["Write then Edit on same file"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  -- Write creates the file
  child.lua([[
    claude._on_pre_tool_use("Write")
    local path = vim.fs.joinpath(_G.TEST_DIR, "evolving.txt")
    local f = io.open(path, "w")
    f:write("v1")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "evolving.txt"), "Write")
    claude._on_session_end()
  ]])

  child.wait(500)

  -- Edit modifies it
  child.lua([[
    claude._on_pre_tool_use("Edit")
    local path = vim.fs.joinpath(_G.TEST_DIR, "evolving.txt")
    local f = io.open(path, "w")
    f:write("v2")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "evolving.txt"), "Edit")
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.total_changes = #changes
    _G.total_checkpoints = #fs_monitor.get_checkpoints(session_id)

    _G.has_v2 = false
    for _, c in ipairs(changes) do
      if c.new_content == "v2" then _G.has_v2 = true end
    end
  ]])

  h.expect_gte(child.lua_get("_G.total_changes"), 2, "Should track both Write and Edit")
  h.eq(2, child.lua_get("_G.total_checkpoints"))
  h.eq(true, child.lua_get("_G.has_v2"))
end

-- ============================================================================
-- Stress: rapid parallel edits (simulates Claude Code making many fast edits)
-- ============================================================================

T["Stress"] = new_set()

T["Stress"]["rapid sequential writes to different files"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  -- Simulate rapid-fire: PreToolUse -> write 10 files quickly -> PostToolUse for each
  child.lua([[
    claude._on_pre_tool_use("Write")

    for i = 1, 10 do
      local path = vim.fs.joinpath(_G.TEST_DIR, "rapid_" .. i .. ".txt")
      local f = io.open(path, "w")
      f:write("content " .. i)
      f:close()
    end
  ]])

  child.wait(1000)

  child.lua([[
    for i = 1, 10 do
      claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "rapid_" .. i .. ".txt"), "Write")
    end
  ]])

  child.wait(500)

  child.lua([[
    claude._on_session_end()
  ]])

  child.wait(1000)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes

    _G.unique_paths = {}
    for _, c in ipairs(changes) do
      _G.unique_paths[c.path] = true
    end
    _G.unique_count = vim.tbl_count(_G.unique_paths)
  ]])

  h.expect_gte(child.lua_get("_G.change_count"), 10, "Should track all 10 file writes")
  h.eq(10, child.lua_get("_G.unique_count"))
end

T["Stress"]["rapid overwrites to the same file"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  -- Simulate rapid repeated edits to a single file (like iterative code refinement)
  child.lua([[
    local path = vim.fs.joinpath(_G.TEST_DIR, "hot_file.txt")
    local f = io.open(path, "w")
    f:write("v0")
    f:close()
  ]])

  child.wait(300)

  -- Ensure prepopulate picks up the file
  child.lua([[
    claude._on_pre_tool_use("Edit")
  ]])

  child.wait(300)

  child.lua([[
    local path = vim.fs.joinpath(_G.TEST_DIR, "hot_file.txt")
    for i = 1, 5 do
      local f = io.open(path, "w")
      f:write("version " .. i)
      f:close()
    end
  ]])

  child.wait(800)

  child.lua([[
    claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "hot_file.txt"), "Edit")
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes
    _G.has_hot_file = false
    for _, c in ipairs(changes) do
      if c.path == "hot_file.txt" then _G.has_hot_file = true end
    end
  ]])

  h.expect_gte(child.lua_get("_G.change_count"), 1, "Should track at least one change to hot_file")
  h.eq(true, child.lua_get("_G.has_hot_file"))
end

T["Stress"]["multiple tool cycles without session end between them"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  -- Claude may fire multiple PreToolUse->PostToolUse cycles in a single response
  child.lua([[
    -- Tool 1: Write file A
    claude._on_pre_tool_use("Write")
    local f1 = io.open(vim.fs.joinpath(_G.TEST_DIR, "multi_a.txt"), "w")
    f1:write("file a")
    f1:close()
  ]])

  child.wait(400)

  child.lua([[
    claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "multi_a.txt"), "Write")
  ]])

  child.wait(200)

  -- Tool 2: Write file B (no session_end between tools)
  child.lua([[
    claude._on_pre_tool_use("Edit")
    local f2 = io.open(vim.fs.joinpath(_G.TEST_DIR, "multi_b.txt"), "w")
    f2:write("file b")
    f2:close()
  ]])

  child.wait(400)

  child.lua([[
    claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "multi_b.txt"), "Edit")
  ]])

  child.wait(200)

  -- Tool 3: Bash modifies file A
  child.lua([[
    claude._on_pre_tool_use("Bash")
    local f3 = io.open(vim.fs.joinpath(_G.TEST_DIR, "multi_a.txt"), "w")
    f3:write("file a updated by bash")
    f3:close()
  ]])

  child.wait(400)

  child.lua([[
    claude._on_file_changed("", "Bash")
  ]])

  child.wait(200)

  -- Now session ends after all three tools
  child.lua([[
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    local checkpoints = fs_monitor.get_checkpoints(session_id)
    _G.total_changes = #changes
    _G.total_checkpoints = #checkpoints

    _G.paths = {}
    for _, c in ipairs(changes) do
      _G.paths[c.path] = true
    end
    _G.has_a = _G.paths["multi_a.txt"] ~= nil
    _G.has_b = _G.paths["multi_b.txt"] ~= nil
  ]])

  h.expect_gte(child.lua_get("_G.total_changes"), 2, "Should capture changes from all tools")
  h.eq(1, child.lua_get("_G.total_checkpoints"))
  h.eq(true, child.lua_get("_G.has_a"))
  h.eq(true, child.lua_get("_G.has_b"))
end

T["Stress"]["burst of 20 files in rapid succession"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    claude._on_pre_tool_use("Write")

    for i = 1, 20 do
      local path = vim.fs.joinpath(_G.TEST_DIR, string.format("burst_%02d.txt", i))
      local f = io.open(path, "w")
      f:write(string.format("burst content %d with some padding to simulate real files", i))
      f:close()
    end
  ]])

  child.wait(1500)

  child.lua([[
    for i = 1, 20 do
      claude._on_file_changed(
        vim.fs.joinpath(_G.TEST_DIR, string.format("burst_%02d.txt", i)),
        "Write"
      )
    end
    claude._on_session_end()
  ]])

  child.wait(1000)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes

    _G.unique_paths = {}
    for _, c in ipairs(changes) do
      _G.unique_paths[c.path] = true
    end
    _G.unique_count = vim.tbl_count(_G.unique_paths)
  ]])

  h.expect_gte(child.lua_get("_G.change_count"), 20, "Should track all 20 burst files")
  h.eq(20, child.lua_get("_G.unique_count"))
end

T["Stress"]["interleaved create-edit-delete cycle"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  -- Create files
  child.lua([[
    claude._on_pre_tool_use("Write")
    for i = 1, 5 do
      local f = io.open(vim.fs.joinpath(_G.TEST_DIR, "lifecycle_" .. i .. ".txt"), "w")
      f:write("created " .. i)
      f:close()
    end
  ]])

  child.wait(500)

  child.lua([[
    for i = 1, 5 do
      claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "lifecycle_" .. i .. ".txt"), "Write")
    end
    claude._on_session_end()
  ]])

  child.wait(500)

  -- Edit some files
  child.lua([[
    claude._on_pre_tool_use("Edit")
    for i = 1, 3 do
      local f = io.open(vim.fs.joinpath(_G.TEST_DIR, "lifecycle_" .. i .. ".txt"), "w")
      f:write("edited " .. i)
      f:close()
    end
  ]])

  child.wait(500)

  child.lua([[
    for i = 1, 3 do
      claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "lifecycle_" .. i .. ".txt"), "Edit")
    end
    claude._on_session_end()
  ]])

  child.wait(500)

  -- Delete some files via bash
  child.lua([[
    claude._on_pre_tool_use("Bash")
    for i = 4, 5 do
      os.remove(vim.fs.joinpath(_G.TEST_DIR, "lifecycle_" .. i .. ".txt"))
    end
  ]])

  child.wait(500)

  child.lua([[
    claude._on_file_changed("", "Bash")
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    local checkpoints = fs_monitor.get_checkpoints(session_id)
    _G.total_changes = #changes
    _G.total_checkpoints = #checkpoints

    _G.created_count = 0
    _G.modified_count = 0
    _G.deleted_count = 0
    for _, c in ipairs(changes) do
      if c.kind == "created" then _G.created_count = _G.created_count + 1 end
      if c.kind == "modified" then _G.modified_count = _G.modified_count + 1 end
      if c.kind == "deleted" then _G.deleted_count = _G.deleted_count + 1 end
    end
  ]])

  h.expect_gte(child.lua_get("_G.total_changes"), 5, "Should track all lifecycle changes")
  h.eq(3, child.lua_get("_G.total_checkpoints"))
  h.expect_gte(child.lua_get("_G.created_count"), 5, "Should have 5 created events")
  h.expect_gte(child.lua_get("_G.modified_count"), 3, "Should have 3 modified events")
  h.expect_gte(child.lua_get("_G.deleted_count"), 2, "Should have 2 deleted events")
end

T["Stress"]["watcher toggle rapid cycle"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  -- Rapidly toggle watcher on/off 10 times (simulates many quick tool calls)
  child.lua([[
    for i = 1, 10 do
      claude._on_pre_tool_use("Write")
      local path = vim.fs.joinpath(_G.TEST_DIR, "toggle_" .. i .. ".txt")
      local f = io.open(path, "w")
      f:write("toggle " .. i)
      f:close()
    end
  ]])

  child.wait(800)

  child.lua([[
    for i = 1, 10 do
      claude._on_file_changed(vim.fs.joinpath(_G.TEST_DIR, "toggle_" .. i .. ".txt"), "Write")
      -- Re-activate for next tool (except last)
      if i < 10 then
        claude._on_pre_tool_use("Write")
      end
    end
  ]])

  child.wait(300)

  child.lua([[
    claude._on_session_end()
  ]])

  child.wait(500)

  child.lua([[
    _G.watcher_final = claude._watcher_active
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes
  ]])

  h.eq(false, child.lua_get("_G.watcher_final"))
  h.expect_gte(child.lua_get("_G.change_count"), 10, "Should track all toggle writes")
end

T["Stress"]["many session end calls without changes are safe"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    for _ = 1, 10 do
      claude._on_session_end()
    end
    _G.cycle = claude._cycle
    local session_id = claude.get_session_id()
    local checkpoints = fs_monitor.get_checkpoints(session_id)
    _G.checkpoint_count = #checkpoints
  ]])

  -- Cycle increments each time, but no checkpoints created without changes
  h.eq(10, child.lua_get("_G.cycle"))
  h.eq(0, child.lua_get("_G.checkpoint_count"))
end

T["Stress"]["subdirectory file creation via bash"] = function()
  child.lua([[
    claude.start({ install_hooks = false })
  ]])

  child.wait(300)

  child.lua([[
    claude._on_pre_tool_use("Bash")
  ]])

  child.wait(200)

  child.lua([[
    local subdir = vim.fs.joinpath(_G.TEST_DIR, "src", "components")
    vim.fn.mkdir(subdir, "p")

    for i = 1, 5 do
      local path = vim.fs.joinpath(subdir, "component_" .. i .. ".lua")
      local f = io.open(path, "w")
      f:write("-- component " .. i)
      f:close()
    end
  ]])

  child.wait(1000)

  child.lua([[
    claude._on_file_changed("", "Bash")
    claude._on_session_end()
  ]])

  child.wait(600)

  child.lua([[
    local session_id = claude.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes

    _G.component_count = 0
    for _, c in ipairs(changes) do
      if c.path:match("component_") then
        _G.component_count = _G.component_count + 1
      end
    end
  ]])

  h.expect_gte(child.lua_get("_G.change_count"), 5, "Should detect subdirectory files")
  h.expect_gte(child.lua_get("_G.component_count"), 5, "All 5 components should be tracked")
end

return T
