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

T["Monitor"] = new_set()

T["Monitor"]["can start and stop a session"] = function()
  child.lua([[
    local session = fs_monitor.create_session({ id = "test_session" })
    _G.watch_id = fs_monitor.start("test_session", _G.TEST_DIR)
  ]])

  local watch_id = child.lua_get("_G.watch_id")
  h.not_eq(nil, watch_id)
  h.not_eq("", watch_id)

  child.lua([[
    _G.stopped = false
    fs_monitor.pause("test_session", function(changes)
      _G.changes = changes
      _G.stopped = true
    end)
  ]])

  child.wait(500, "_G.stopped == true")
  local changes = child.lua_get("_G.changes")
  h.eq({}, changes)
end

T["Monitor"]["detects file creation"] = function()
  child.lua([[
    fs_monitor.create_session({ id = "test_creation" })
    fs_monitor.start("test_creation", _G.TEST_DIR)

    vim.wait(100)

    -- Create a file
    local f = io.open(vim.fs.joinpath(_G.TEST_DIR, "hello.txt"), "w")
    f:write("hello world")
    f:close()
  ]])

  -- Wait for debounce
  child.wait(1000)

  child.lua([[
    _G.stopped = false
    fs_monitor.pause("test_creation", function(changes)
      _G.changes = changes
      _G.stopped = true
    end)
  ]])

  child.wait(1000, "_G.stopped == true")
  local changes = child.lua_get("_G.changes")

  h.eq(1, #changes)
  h.eq("hello.txt", changes[1].path)
  h.eq("created", changes[1].kind)
  h.eq("hello world", changes[1].new_content)
end

T["Monitor"]["detects file modification"] = function()
  child.lua([[
    -- Create initial file
    local path = vim.fs.joinpath(_G.TEST_DIR, "mod.txt")
    local f = io.open(path, "w")
    f:write("original")
    f:close()

    fs_monitor.create_session({ id = "test_mod" })
    fs_monitor.start("test_mod", _G.TEST_DIR)

    -- Wait for prepopulate
    vim.wait(200)

    -- Modify file
    f = io.open(path, "w")
    f:write("modified")
    f:close()
  ]])

  child.wait(1000)

  child.lua([[
    _G.stopped = false
    fs_monitor.pause("test_mod", function(changes)
      _G.changes = changes
      _G.stopped = true
    end)
  ]])

  child.wait(1000, "_G.stopped == true")
  local changes = child.lua_get("_G.changes")

  h.eq(1, #changes)
  h.eq("mod.txt", changes[1].path)
  h.eq("modified", changes[1].kind)
  h.eq("original", changes[1].old_content)
  h.eq("modified", changes[1].new_content)
end

T["Monitor"]["detects file deletion"] = function()
  child.lua([[
    -- Create initial file
    local path = vim.fs.joinpath(_G.TEST_DIR, "del.txt")
    local f = io.open(path, "w")
    f:write("to be deleted")
    f:close()

    fs_monitor.create_session({ id = "test_del" })
    fs_monitor.start("test_del", _G.TEST_DIR)

    -- Wait for prepopulate
    vim.wait(200)

    -- Delete file
    os.remove(path)
  ]])

  child.wait(1000)

  child.lua([[
    _G.stopped = false
    fs_monitor.pause("test_del", function(changes)
      _G.changes = changes
      _G.stopped = true
    end)
  ]])

  child.wait(1000, "_G.stopped == true")
  local changes = child.lua_get("_G.changes")

  h.eq(1, #changes)
  h.eq("del.txt", changes[1].path)
  h.eq("deleted", changes[1].kind)
  h.eq("to be deleted", changes[1].old_content)
end

T["Session"] = new_set()

T["Session"]["creates session with custom id"] = function()
  child.lua([[
    local session = fs_monitor.create_session({ id = "custom_id_123" })
    _G.session_id = session.id
  ]])

  h.eq("custom_id_123", child.lua_get("_G.session_id"))
end

T["Session"]["creates session with auto-generated id"] = function()
  child.lua([[
    local session = fs_monitor.create_session()
    _G.session_id = session.id
    _G.has_session_prefix = session.id:match("^session_") ~= nil
  ]])

  h.eq(true, child.lua_get("_G.has_session_prefix"))
end

T["Session"]["stores custom metadata"] = function()
  child.lua([[
    local session = fs_monitor.create_session({
      id = "meta_test",
      metadata = { tool = "test_tool", user = "test_user" }
    })
    _G.metadata = session.metadata
  ]])

  local metadata = child.lua_get("_G.metadata")
  h.eq("test_tool", metadata.tool)
  h.eq("test_user", metadata.user)
end

T["Session"]["get_session returns correct session"] = function()
  child.lua([[
    fs_monitor.create_session({ id = "session_to_find" })
    local found = fs_monitor.get_session("session_to_find")
    _G.found = found ~= nil
    _G.found_id = found and found.id or nil
  ]])

  h.eq(true, child.lua_get("_G.found"))
  h.eq("session_to_find", child.lua_get("_G.found_id"))
end

T["Session"]["get_session returns nil for nonexistent session"] = function()
  child.lua([[
    local found = fs_monitor.get_session("nonexistent_session")
    _G.found = found
  ]])

  h.eq(vim.NIL, child.lua_get("_G.found"))
end

T["Session"]["supports multiple concurrent sessions"] = function()
  child.lua([[
    local s1 = fs_monitor.create_session({ id = "session_1" })
    local s2 = fs_monitor.create_session({ id = "session_2" })
    local s3 = fs_monitor.create_session({ id = "session_3" })

    local all = fs_monitor.get_all_sessions()
    _G.session_count = vim.tbl_count(all)
    _G.has_s1 = all["session_1"] ~= nil
    _G.has_s2 = all["session_2"] ~= nil
    _G.has_s3 = all["session_3"] ~= nil
  ]])

  h.eq(3, child.lua_get("_G.session_count"))
  h.eq(true, child.lua_get("_G.has_s1"))
  h.eq(true, child.lua_get("_G.has_s2"))
  h.eq(true, child.lua_get("_G.has_s3"))
end

T["Session"]["destroy removes session"] = function()
  child.lua([[
    fs_monitor.create_session({ id = "to_destroy" })
    _G.exists_before = fs_monitor.get_session("to_destroy") ~= nil

    _G.destroyed = false
    fs_monitor.destroy("to_destroy", function()
      _G.destroyed = true
    end)
  ]])

  child.wait(500, "_G.destroyed == true")

  child.lua([[
    _G.exists_after = fs_monitor.get_session("to_destroy") ~= nil
  ]])

  h.eq(true, child.lua_get("_G.exists_before"))
  h.eq(false, child.lua_get("_G.exists_after"))
end

T["Session"]["clear_all removes all sessions"] = function()
  child.lua([[
    fs_monitor.create_session({ id = "clear_1" })
    fs_monitor.create_session({ id = "clear_2" })
    _G.count_before = vim.tbl_count(fs_monitor.get_all_sessions())

    _G.cleared = false
    fs_monitor.clear_all(function()
      _G.cleared = true
    end)
  ]])

  child.wait(500, "_G.cleared == true")

  child.lua([[
    _G.count_after = vim.tbl_count(fs_monitor.get_all_sessions())
  ]])

  h.eq(2, child.lua_get("_G.count_before"))
  h.eq(0, child.lua_get("_G.count_after"))
end

T["Checkpoint"] = new_set()

T["Checkpoint"]["creates checkpoint for session"] = function()
  child.lua([[
    fs_monitor.create_session({ id = "cp_test" })
    fs_monitor.start("cp_test", _G.TEST_DIR)
    vim.wait(100)

    local checkpoint = fs_monitor.create_checkpoint("cp_test", "Test checkpoint")
    _G.checkpoint = checkpoint
    _G.has_timestamp = checkpoint and checkpoint.timestamp ~= nil
    _G.has_label = checkpoint and checkpoint.label == "Test checkpoint"
  ]])

  h.eq(true, child.lua_get("_G.has_timestamp"))
  h.eq(true, child.lua_get("_G.has_label"))
end

T["Checkpoint"]["get_checkpoints returns checkpoints"] = function()
  child.lua([[
    fs_monitor.create_session({ id = "cp_list" })
    fs_monitor.start("cp_list", _G.TEST_DIR)
    vim.wait(100)

    fs_monitor.create_checkpoint("cp_list", "First")
    fs_monitor.create_checkpoint("cp_list", "Second")

    local checkpoints = fs_monitor.get_checkpoints("cp_list")
    _G.count = #checkpoints
    _G.first_label = checkpoints[1] and checkpoints[1].label
    _G.second_label = checkpoints[2] and checkpoints[2].label
  ]])

  h.eq(2, child.lua_get("_G.count"))
  h.eq("First", child.lua_get("_G.first_label"))
  h.eq("Second", child.lua_get("_G.second_label"))
end

T["Stats"] = new_set()

T["Stats"]["get_stats returns nil for nonexistent session"] = function()
  child.lua([[
    _G.stats = fs_monitor.get_stats("nonexistent")
  ]])

  h.eq(vim.NIL, child.lua_get("_G.stats"))
end

T["Stats"]["get_stats returns stats for valid session"] = function()
  child.lua([[
    fs_monitor.create_session({ id = "stats_test" })
    fs_monitor.start("stats_test", _G.TEST_DIR)
    vim.wait(100)

    -- Create a file to generate a change
    local f = io.open(vim.fs.joinpath(_G.TEST_DIR, "stat_file.txt"), "w")
    f:write("stats")
    f:close()
  ]])

  child.wait(1000)

  child.lua([[
    _G.stats = fs_monitor.get_stats("stats_test")
    _G.has_total = _G.stats and _G.stats.total_changes ~= nil
    _G.has_active = _G.stats and _G.stats.active_watches ~= nil
  ]])

  h.eq(true, child.lua_get("_G.has_total"))
  h.eq(true, child.lua_get("_G.has_active"))
end

return T
