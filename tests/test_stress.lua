local h = require("tests.helpers")
local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        Monitor = require("fs-monitor.monitor")
        _G.TEST_DIR = vim.fn.tempname()
        vim.fn.mkdir(_G.TEST_DIR, "p")
        vim.uv.chdir(_G.TEST_DIR)

        _G.run_phase = function(phase_fn)
            phase_fn()
            vim.wait(2000)
        end

        _G.count_changes = function(m)
           return #m:get_all_changes()
        end

        _G.ensure_exists = function(path)
           local stat = vim.uv.fs_stat(path)
           return stat ~= nil
        end
      ]])
    end,
    post_case = function()
      child.lua([[
        pcall(vim.fn.delete, _G.TEST_DIR, "rf")
      ]])
    end,
    post_once = child.stop,
  },
})

T["StressTest"] = new_set()

T["StressTest"]["FullScenario"] = function()
  child.lua([[
    local m = Monitor.new({ debounce_ms = 100 })
    _G.m = m

    vim.uv.fs_mkdir("dir", 511)

    _G.p1_ready = false
    local w1 = m:start_monitoring("stress", _G.TEST_DIR, {
      recursive = true,
      on_ready = function() _G.p1_ready = true end
    })

    vim.wait(2000, function() return _G.p1_ready end)

    -- Phase 1
    local f = io.open("hi.lua", "w"); f:write("hi"); f:close()

    vim.uv.fs_mkdir("dir1", 511)

    vim.fn.mkdir("dir2/dir3", "p")
    local f = io.open("dir2/dir3/hello.lua", "w"); f:write("hello"); f:close()

    local f = io.open("dir1/salute.lua", "w"); f:write("salute"); f:close()

    vim.wait(500)

    os.remove("dir1/salute.lua")

    -- Wait for debounce + async operations
    vim.wait(1500)

    _G.cp1 = m:create_checkpoint()

    vim.wait(500)

    _G.w1_stopped = false
    m:stop_monitoring_async(w1, function() _G.w1_stopped = true end)
    vim.wait(2000, function() return _G.w1_stopped end)

    vim.wait(500)

    -- Phase 2

    _G.p2_ready = false
    local w2 = m:start_monitoring("stress", _G.TEST_DIR, {
       recursive = true,
       on_ready = function() _G.p2_ready = true end
    })

    vim.wait(2000, function() return _G.p2_ready end)

    os.rename("hi.lua", "hi1.lua")

    os.remove("dir1/salute.lua")

    vim.wait(500) -- wait for rename to settle
    os.remove("hi1.lua")

    vim.uv.fs_mkdir("dir0", 511)
    local f = io.open("dir0/mer.lua", "w"); f:write("mer"); f:close()

    -- Wait for debounce + async operations
    vim.wait(1500)

    _G.cp2 = m:create_checkpoint()

    vim.wait(500)

    _G.w2_stopped = false
    m:stop_monitoring_async(w2, function() _G.w2_stopped = true end)
    vim.wait(2000, function() return _G.w2_stopped end)

    vim.wait(500)

    -- Phase 3
    _G.p3_ready = false
    local w3 = m:start_monitoring("stress", _G.TEST_DIR, {
      recursive = true,
      on_ready = function() _G.p3_ready = true end
    })

    vim.wait(2000, function() return _G.p3_ready end)

    os.remove("dir0/mer.lua")

    vim.wait(1500)
    vim.uv.fs_rmdir("dir0")

    os.rename("dir2/dir3/hello.lua", "dir2/dir3/hello1.lua")

    vim.wait(500)

    os.remove("dir2/dir3/hello1.lua")

    -- Wait for debounce (100ms) + async file reads to complete
    vim.wait(2000)

    _G.cp3 = m:create_checkpoint()

    -- Additional wait to ensure all async operations are truly done
    vim.wait(500)

    _G.w3_stopped = false
    m:stop_monitoring_async(w3, function() _G.w3_stopped = true end)
    vim.wait(2000, function() return _G.w3_stopped end)

    -- Extra settling time after watcher stops
    vim.wait(500)

    _G.checkpoints = { _G.cp1, _G.cp2, _G.cp3 }

    -- Wait for any pending filesystem events to be processed
    vim.wait(500)

    -- Debug: Check what changes were recorded in phase 3
    _G.all_changes = m:get_all_changes()
    _G.phase3_changes = {}
    for _, change in ipairs(_G.all_changes) do
      if change.timestamp > _G.cp2.timestamp then
        table.insert(_G.phase3_changes, {
          path = change.path,
          kind = change.kind,
          has_old = change.old_content ~= nil,
          has_new = change.new_content ~= nil,
          old_path = change.metadata and change.metadata.old_path or nil,
        })
      end
    end

    _G.total_changes = #_G.all_changes
    _G.cp2_change_count = _G.cp2.change_count

    -- Phase 3 had: mer deleted, hello->hello1 rename, hello1 deleted
    -- Expect: mer restored, hello1 restored then renamed back to hello
    -- So hello should exist. mer should exist.
    local res2 = m:revert_to_checkpoint(2, _G.checkpoints)
    _G.res2 = res2

    -- Wait until expected filesystem state is observed (or timeout)
    vim.wait(3000, function()
      local has_mer = _G.ensure_exists("dir0/mer.lua")
      local has_hello = _G.ensure_exists("dir2/dir3/hello.lua")
      local has_hello1 = _G.ensure_exists("dir2/dir3/hello1.lua")
      return has_mer and has_hello and (not has_hello1)
    end)

    _G.has_mer = _G.ensure_exists("dir0/mer.lua")
    _G.has_hello = _G.ensure_exists("dir2/dir3/hello.lua")
    _G.has_hello1 = _G.ensure_exists("dir2/dir3/hello1.lua")

  ]])

  -- Debug output
  local phase3_changes = child.lua_get("_G.phase3_changes")
  local res2 = child.lua_get("_G.res2")
  local total_changes = child.lua_get("_G.total_changes")
  local cp2_change_count = child.lua_get("_G.cp2_change_count")

  print("\n=== DEBUG INFO ===")
  print("Total changes recorded: " .. tostring(total_changes))
  print("CP2 change count: " .. tostring(cp2_change_count))
  print("\n=== Phase 3 Changes (after CP2) ===")
  print(vim.inspect(phase3_changes))
  print("\n=== Revert Result ===")
  print("Reverted count: " .. tostring(res2 and res2.reverted_count or "nil"))
  print("Error count: " .. tostring(res2 and res2.error_count or "nil"))
  print("\n=== File State After Revert ===")
  print("has_mer: " .. tostring(child.lua_get("_G.has_mer")))
  print("has_hello: " .. tostring(child.lua_get("_G.has_hello")))
  print("has_hello1: " .. tostring(child.lua_get("_G.has_hello1")))

  -- Check if dir0 exists
  child.lua([[_G.has_dir0 = _G.ensure_exists("dir0")]])
  print("has_dir0: " .. tostring(child.lua_get("_G.has_dir0")))
  print("==================\n")

  h.eq(true, child.lua_get("_G.has_mer"), "mer.lua should be restored")
  h.eq(true, child.lua_get("_G.has_hello"), "hello.lua should be restored")
  h.eq(false, child.lua_get("_G.has_hello1"), "hello1.lua should be gone")

  child.lua([[
    -- Phase 2 had: hi->hi1 rename, hi1 delete, mer create
    -- Current state (after revert to CP2): mer exists, hi1 is deleted (from Phase 2), hi is gone (renamed in P2)
    -- Revert P2:
    -- mer created -> delete mer
    -- hi1 deleted -> restore hi1
    -- hi->hi1 renamed -> rename hi1 to hi

    vim.wait(500)

    local res1 = m:revert_to_checkpoint(1, _G.checkpoints)
    _G.res1 = res1

    vim.wait(3000, function()
      local has_mer = _G.ensure_exists("dir0/mer.lua")
      local has_hi = _G.ensure_exists("hi.lua")
      local has_hi1 = _G.ensure_exists("hi1.lua")
      return (not has_mer) and has_hi and (not has_hi1)
    end)

    _G.has_mer_p1 = _G.ensure_exists("dir0/mer.lua")
    _G.has_hi = _G.ensure_exists("hi.lua")
    _G.has_hi1 = _G.ensure_exists("hi1.lua")



  ]])

  h.eq(false, child.lua_get("_G.has_mer_p1"), "mer.lua should be deleted")
  h.eq(true, child.lua_get("_G.has_hi"), "hi.lua should be restored")
  h.eq(false, child.lua_get("_G.has_hi1"), "hi1.lua should be gone")

  child.lua([[
    -- Phase 1: hi created, hello created, salute created, salute deleted
    -- Current state: hi exists, hello exists. salute gone.
    -- Revert P1:
    -- salute deleted -> restore salute
    -- salute created -> delete salute
    -- hello created -> delete hello
    -- hi created -> delete hi

    vim.wait(500)

    local res0 = m:revert_to_original(_G.checkpoints)

    vim.wait(3000, function()
      local has_hi = _G.ensure_exists("hi.lua")
      local has_hello = _G.ensure_exists("dir2/dir3/hello.lua")
      local has_salute = _G.ensure_exists("dir1/salute.lua")
      local has_dir1 = _G.ensure_exists("dir1")
      local has_dir2 = _G.ensure_exists("dir2")
      return (not has_hi) and (not has_hello) and (not has_salute) and (not has_dir1) and (not has_dir2)
    end)

    _G.has_hi_orig = _G.ensure_exists("hi.lua")
    _G.has_hello_orig = _G.ensure_exists("dir2/dir3/hello.lua")
    _G.has_salute_orig = _G.ensure_exists("dir1/salute.lua")

    _G.has_dir1 = _G.ensure_exists("dir1")
    _G.has_dir2 = _G.ensure_exists("dir2")

    -- Debug: Check what's in dir1 if it exists
    _G.dir1_contents = {}
    if _G.has_dir1 then
      local handle = vim.uv.fs_scandir("dir1")
      if handle then
        while true do
          local name, type = vim.uv.fs_scandir_next(handle)
          if not name then break end
          table.insert(_G.dir1_contents, { name = name, type = type })
        end
      end
    end

    -- Check what's in dir2 if it exists
    _G.dir2_contents = {}
    if _G.has_dir2 then
      local handle = vim.uv.fs_scandir("dir2")
      if handle then
        while true do
          local name, type = vim.uv.fs_scandir_next(handle)
          if not name then break end
          table.insert(_G.dir2_contents, { name = name, type = type })
        end
      end
    end
  ]])

  print("\n=== After Revert to Original ===")
  print("has_hi_orig: " .. tostring(child.lua_get("_G.has_hi_orig")))
  print("has_hello_orig: " .. tostring(child.lua_get("_G.has_hello_orig")))
  print("has_salute_orig: " .. tostring(child.lua_get("_G.has_salute_orig")))
  print("has_dir1: " .. tostring(child.lua_get("_G.has_dir1")))
  print("has_dir2: " .. tostring(child.lua_get("_G.has_dir2")))

  local dir1_contents = child.lua_get("_G.dir1_contents")
  local dir2_contents = child.lua_get("_G.dir2_contents")
  print("\ndir1 contents: " .. vim.inspect(dir1_contents))
  print("dir2 contents: " .. vim.inspect(dir2_contents))
  print("==================\n")

  h.eq(false, child.lua_get("_G.has_hi_orig"), "hi.lua should be deleted")
  h.eq(false, child.lua_get("_G.has_hello_orig"), "hello.lua should be deleted")
  h.eq(false, child.lua_get("_G.has_salute_orig"), "salute.lua should be deleted (restored then deleted)")
  h.eq(false, child.lua_get("_G.has_dir1"), "dir1 should be deleted (empty)")
  h.eq(false, child.lua_get("_G.has_dir2"), "dir2 should be deleted (empty)")
end

return T
