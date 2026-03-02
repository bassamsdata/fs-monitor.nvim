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
        oc = require("fs-monitor.providers.opencode")

        _G.TEST_DIR = vim.fn.tempname()
        vim.fn.mkdir(_G.TEST_DIR, "p")
        vim.uv.chdir(_G.TEST_DIR)

        -- MOCKS
        oc._original_install_plugin = oc.install_plugin
        oc.install_plugin = function(_, on_done)
          if on_done then on_done(true) end
        end

        oc.uninstall_plugin = function(_, on_done)
          if on_done then on_done() end
        end
      ]])
    end,
    post_case = function()
      child.lua([[
        if oc._session_id then
          pcall(function()
            oc.stop({ keep_plugin = true })
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

T["Session"]["start creates a session in plugin mode"] = function()
  child.lua([[
    oc.start()
  ]])

  child.wait(500)

  child.lua([[
    _G.session_id = oc._session_id
    _G.mode = oc._mode
    _G.is_active = oc.is_active()
  ]])

  h.expect_not_nil(child.lua_get("_G.session_id"), "Session ID should be set")
  h.eq("plugin", child.lua_get("_G.mode"))
  h.eq(true, child.lua_get("_G.is_active"))
end

T["Session"]["start warns on duplicate session"] = function()
  child.lua([[
    oc.start()
  ]])

  child.wait(300)

  child.lua([[
    _G.first_session = oc._session_id
    oc.start()
    _G.second_session = oc._session_id
  ]])

  child.wait(300)

  -- Should keep the same session
  h.eq(child.lua_get("_G.first_session"), child.lua_get("_G.second_session"))
end

T["Session"]["stop destroys session"] = function()
  child.lua([[
    oc.start()
  ]])

  child.wait(300)

  child.lua([[
    oc.stop({ keep_plugin = true })
    _G.session_id = oc._session_id
    _G.is_active = oc.is_active()
  ]])

  h.eq(vim.NIL, child.lua_get("_G.session_id"))
  h.eq(false, child.lua_get("_G.is_active"))
end

-- ============================================================================
-- Tool Lifecycle: pre/post tool use (simulates JS plugin RPC calls)
-- ============================================================================

T["ToolLifecycle"] = new_set()

T["ToolLifecycle"]["pre_tool_use activates watcher"] = function()
  child.lua([[
    oc.start()
  ]])

  child.wait(300)

  child.lua([[
    _G.watcher_before = oc._watcher_active
    oc._on_pre_tool_use("write")
    _G.watcher_after = oc._watcher_active
    _G.inflight = oc._inflight_tools
  ]])

  h.eq(false, child.lua_get("_G.watcher_before"))
  h.eq(true, child.lua_get("_G.watcher_after"))
  h.eq(1, child.lua_get("_G.inflight"))
end

T["ToolLifecycle"]["post_tool_use deactivates watcher"] = function()
  child.lua([[
    oc.start()
  ]])

  child.wait(300)

  child.lua([[
    oc._on_pre_tool_use("write")
    _G.watcher_active_during = oc._watcher_active
    oc._on_post_tool_use("", "write")
    _G.watcher_active_after = oc._watcher_active
    _G.inflight = oc._inflight_tools
  ]])

  h.eq(true, child.lua_get("_G.watcher_active_during"))
  h.eq(false, child.lua_get("_G.watcher_active_after"))
  h.eq(0, child.lua_get("_G.inflight"))
end

T["ToolLifecycle"]["watcher stays active with multiple inflight tools"] = function()
  child.lua([[
    oc.start()
  ]])

  child.wait(300)

  child.lua([[
    oc._on_pre_tool_use("read")
    oc._on_pre_tool_use("write")
    _G.inflight_2 = oc._inflight_tools
    _G.watcher_2 = oc._watcher_active

    oc._on_post_tool_use("", "read")
    _G.inflight_1 = oc._inflight_tools
    _G.watcher_still_active = oc._watcher_active

    oc._on_post_tool_use("", "write")
    _G.inflight_0 = oc._inflight_tools
    _G.watcher_now_off = oc._watcher_active
  ]])

  h.eq(2, child.lua_get("_G.inflight_2"))
  h.eq(true, child.lua_get("_G.watcher_2"))
  h.eq(1, child.lua_get("_G.inflight_1"))
  h.eq(true, child.lua_get("_G.watcher_still_active"))
  h.eq(0, child.lua_get("_G.inflight_0"))
  h.eq(false, child.lua_get("_G.watcher_now_off"))
end

-- ============================================================================
-- Write Tool: file creation detected via watcher
-- ============================================================================

T["WriteTool"] = new_set()

T["WriteTool"]["detects file creation via watcher"] = function()
  child.lua([[
    oc.start()
  ]])

  child.wait(300)

  child.lua([[
    -- Simulate: tool.execute.before → create file → tool.execute.after
    oc._on_pre_tool_use("write")

    local path = vim.fs.joinpath(_G.TEST_DIR, "created.txt")
    local f = io.open(path, "w")
    f:write("hello world")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    oc._on_post_tool_use(vim.fs.joinpath(_G.TEST_DIR, "created.txt"), "write")
  ]])

  child.wait(300)

  child.lua([[
    oc._on_session_complete()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = oc._session_id or oc.get_session_id()
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

    oc.start()
  ]])

  child.wait(500)

  child.lua([[
    oc._on_pre_tool_use("edit")

    local path = vim.fs.joinpath(_G.TEST_DIR, "existing.txt")
    local f = io.open(path, "w")
    f:write("modified content")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    oc._on_post_tool_use(vim.fs.joinpath(_G.TEST_DIR, "existing.txt"), "edit")
    oc._on_session_complete()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = oc.get_session_id()
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
-- Bash Tool: file changes detected via watcher (core scenario)
-- ============================================================================

T["BashTool"] = new_set()

T["BashTool"]["detects file creation from bash tool"] = function()
  child.lua([[
    oc.start()
  ]])

  child.wait(300)

  child.lua([[
    -- Simulate: bash tool creates a file (no file_path reported)
    oc._on_pre_tool_use("bash")

    local path = vim.fs.joinpath(_G.TEST_DIR, "bash_created.txt")
    local f = io.open(path, "w")
    f:write("created by bash")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    oc._on_post_tool_use("", "bash")
    oc._on_session_complete()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = oc.get_session_id()
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

    oc.start()
  ]])

  child.wait(500)

  child.lua([[
    -- Simulate: bash tool does "mv before_mv.txt after_mv.txt"
    oc._on_pre_tool_use("bash")

    local src = vim.fs.joinpath(_G.TEST_DIR, "before_mv.txt")
    local dst = vim.fs.joinpath(_G.TEST_DIR, "after_mv.txt")
    os.rename(src, dst)
  ]])

  child.wait(500)

  child.lua([[
    oc._on_post_tool_use("", "bash")
    oc._on_session_complete()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = oc.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes

    -- Look for a rename or created+deleted pair
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

    oc.start()
  ]])

  child.wait(500)

  child.lua([[
    -- Simulate: bash tool does "rm to_delete.txt"
    oc._on_pre_tool_use("bash")

    local path = vim.fs.joinpath(_G.TEST_DIR, "to_delete.txt")
    os.remove(path)
  ]])

  child.wait(500)

  child.lua([[
    oc._on_post_tool_use("", "bash")
    oc._on_session_complete()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = oc.get_session_id()
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
-- Session Complete & Checkpoints
-- ============================================================================

T["SessionComplete"] = new_set()

T["SessionComplete"]["session_complete creates checkpoint"] = function()
  child.lua([[
    oc.start()
  ]])

  child.wait(300)

  child.lua([[
    oc._on_pre_tool_use("write")
    local path = vim.fs.joinpath(_G.TEST_DIR, "checkpoint_test.txt")
    local f = io.open(path, "w")
    f:write("checkpoint data")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    oc._on_post_tool_use(vim.fs.joinpath(_G.TEST_DIR, "checkpoint_test.txt"), "write")
    oc._on_session_complete()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = oc.get_session_id()
    local checkpoints = fs_monitor.get_checkpoints(session_id)
    _G.checkpoint_count = #checkpoints
    if #checkpoints > 0 then
      _G.checkpoint_label = checkpoints[1].label
    end
  ]])

  h.expect_gte(child.lua_get("_G.checkpoint_count"), 1, "Should create at least one checkpoint")
  h.eq("Response #1", child.lua_get("_G.checkpoint_label"))
end

T["SessionComplete"]["session_complete increments cycle counter"] = function()
  child.lua([[
    oc.start()
  ]])

  child.wait(300)

  child.lua([[
    _G.cycle_before = oc._cycle

    oc._on_pre_tool_use("write")
    local f = io.open(vim.fs.joinpath(_G.TEST_DIR, "cycle1.txt"), "w")
    f:write("cycle 1")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    oc._on_post_tool_use(vim.fs.joinpath(_G.TEST_DIR, "cycle1.txt"), "write")
    oc._on_session_complete()
  ]])

  child.wait(500)

  child.lua([[
    _G.cycle_after_1 = oc._cycle

    oc._on_pre_tool_use("write")
    local f = io.open(vim.fs.joinpath(_G.TEST_DIR, "cycle2.txt"), "w")
    f:write("cycle 2")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    oc._on_post_tool_use(vim.fs.joinpath(_G.TEST_DIR, "cycle2.txt"), "write")
    oc._on_session_complete()
  ]])

  child.wait(500)

  child.lua([[
    _G.cycle_after_2 = oc._cycle
  ]])

  h.eq(0, child.lua_get("_G.cycle_before"))
  h.eq(1, child.lua_get("_G.cycle_after_1"))
  h.eq(2, child.lua_get("_G.cycle_after_2"))
end

T["SessionComplete"]["session_complete resets inflight tools"] = function()
  child.lua([[
    oc.start()
  ]])

  child.wait(300)

  child.lua([[
    -- Simulate orphaned inflight count (tool crashed)
    oc._inflight_tools = 3
    oc._on_session_complete()
    _G.inflight_after = oc._inflight_tools
  ]])

  child.wait(300)

  h.eq(0, child.lua_get("_G.inflight_after"))
end

T["SessionComplete"]["session_complete deactivates watcher"] = function()
  child.lua([[
    oc.start()
  ]])

  child.wait(300)

  child.lua([[
    oc._on_pre_tool_use("bash")
    _G.watcher_during = oc._watcher_active
    -- Simulate: session.idle fires while watcher is still active
    oc._on_session_complete()
    _G.watcher_after = oc._watcher_active
  ]])

  child.wait(300)

  h.eq(true, child.lua_get("_G.watcher_during"))
  h.eq(false, child.lua_get("_G.watcher_after"))
end

-- ============================================================================
-- File Changed (file.edited event)
-- ============================================================================

T["FileChanged"] = new_set()

T["FileChanged"]["on_file_changed registers modification"] = function()
  child.lua([[
    local path = vim.fs.joinpath(_G.TEST_DIR, "edited.txt")
    local f = io.open(path, "w")
    f:write("original")
    f:close()

    oc.start()
  ]])

  child.wait(500)

  child.lua([[
    local path = vim.fs.joinpath(_G.TEST_DIR, "edited.txt")
    local f = io.open(path, "w")
    f:write("edited via opencode")
    f:close()

    oc._on_file_changed(path)
  ]])

  child.wait(500)

  child.lua([[
    local session_id = oc.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes
    if #changes > 0 then
      _G.last_kind = changes[#changes].kind
      _G.old_content = changes[#changes].old_content
      _G.last_content = changes[#changes].new_content
    end
  ]])

  h.expect_gte(child.lua_get("_G.change_count"), 1, "file.edited should register a change")
  h.eq("modified", child.lua_get("_G.last_kind"))
  h.eq("original", child.lua_get("_G.old_content"))
  h.eq("edited via opencode", child.lua_get("_G.last_content"))
end

T["FileChanged"]["on_file_changed handles deleted file"] = function()
  child.lua([[
    local path = vim.fs.joinpath(_G.TEST_DIR, "ghost.txt")
    local f = io.open(path, "w")
    f:write("temporary")
    f:close()

    oc.start()
  ]])

  child.wait(500)

  child.lua([[
    local path = vim.fs.joinpath(_G.TEST_DIR, "ghost.txt")
    os.remove(path)

    -- file.edited event fires but file is already gone
    oc._on_file_changed(path)
  ]])

  child.wait(1000)

  child.lua([[
    local session_id = oc.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    _G.change_count = #changes
    _G.has_deleted = false
    for _, c in ipairs(changes) do
      if c.kind == "deleted" then
        _G.has_deleted = true
      end
    end
  ]])

  if child.lua_get("_G.change_count") > 0 then h.eq(true, child.lua_get("_G.has_deleted")) end
end

-- ============================================================================
-- Guard: no session
-- ============================================================================

T["Guards"] = new_set()

T["Guards"]["pre_tool_use noop without session"] = function()
  child.lua([[
    _G.result = oc._on_pre_tool_use("write")
    _G.watcher = oc._watcher_active
  ]])

  h.eq("", child.lua_get("_G.result"))
  h.eq(false, child.lua_get("_G.watcher"))
end

T["Guards"]["post_tool_use noop without session"] = function()
  child.lua([[
    _G.result = oc._on_post_tool_use("/some/file.txt", "write")
  ]])

  h.eq("", child.lua_get("_G.result"))
end

T["Guards"]["session_complete noop without session"] = function()
  child.lua([[
    _G.result = oc._on_session_complete()
  ]])

  h.eq("", child.lua_get("_G.result"))
end

T["Guards"]["file_changed noop without session"] = function()
  child.lua([[
    _G.result = oc._on_file_changed("/some/file.txt")
  ]])

  h.eq("", child.lua_get("_G.result"))
end

-- ============================================================================
-- Full Workflow: multi-response session
-- ============================================================================

T["Workflow"] = new_set()

T["Workflow"]["full multi-tool response cycle"] = function()
  child.lua([[
    oc.start()
  ]])

  child.wait(300)

  -- Response 1: write a file
  child.lua([[
    oc._on_pre_tool_use("write")
    local f = io.open(vim.fs.joinpath(_G.TEST_DIR, "response1.txt"), "w")
    f:write("first response")
    f:close()
  ]])

  child.wait(500)

  child.lua([[
    oc._on_post_tool_use(vim.fs.joinpath(_G.TEST_DIR, "response1.txt"), "write")
    oc._on_session_complete()
  ]])

  child.wait(500)

  -- Response 2: bash mv
  child.lua([[
    oc._on_pre_tool_use("bash")
    os.rename(
      vim.fs.joinpath(_G.TEST_DIR, "response1.txt"),
      vim.fs.joinpath(_G.TEST_DIR, "renamed.txt")
    )
  ]])

  child.wait(500)

  child.lua([[
    oc._on_post_tool_use("", "bash")
    oc._on_session_complete()
  ]])

  child.wait(500)

  child.lua([[
    local session_id = oc.get_session_id()
    local changes = fs_monitor.get_changes(session_id)
    local checkpoints = fs_monitor.get_checkpoints(session_id)
    _G.total_changes = #changes
    _G.total_checkpoints = #checkpoints
    _G.cycle = oc._cycle
  ]])

  h.expect_gte(child.lua_get("_G.total_changes"), 2, "Should have changes from both responses")
  h.eq(2, child.lua_get("_G.total_checkpoints"))
  h.eq(2, child.lua_get("_G.cycle"))
end

return T
