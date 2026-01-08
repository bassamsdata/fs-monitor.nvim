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
        -- Stop any running monitors
        if _G.m then
          pcall(function()
            if _G.m.stop_all_async then
              _G.m:stop_all_async(function() end)
            end
          end)
        end

        -- Clear globals
        _G.m = nil

        -- Clean up test directory
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

    vim.wait(800)

    _G.cp1 = m:create_checkpoint()

    _G.w1_stopped = false
    m:stop_monitoring_async(w1, function() _G.w1_stopped = true end)
    vim.wait(1500, function() return _G.w1_stopped end)

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

    vim.wait(800)

    _G.cp2 = m:create_checkpoint()

    _G.w2_stopped = false
    m:stop_monitoring_async(w2, function() _G.w2_stopped = true end)
    vim.wait(1500, function() return _G.w2_stopped end)

    -- Phase 3
    _G.p3_ready = false
    local w3 = m:start_monitoring("stress", _G.TEST_DIR, {
      recursive = true,
      on_ready = function() _G.p3_ready = true end
    })

    vim.wait(2000, function() return _G.p3_ready end)

    os.remove("dir0/mer.lua")

    vim.wait(800)
    vim.uv.fs_rmdir("dir0")

    os.rename("dir2/dir3/hello.lua", "dir2/dir3/hello1.lua")

    vim.wait(300)

    os.remove("dir2/dir3/hello1.lua")

    vim.wait(800)

    _G.cp3 = m:create_checkpoint()

    _G.w3_stopped = false
    m:stop_monitoring_async(w3, function() _G.w3_stopped = true end)
    vim.wait(1500, function() return _G.w3_stopped end)

    _G.checkpoints = { _G.cp1, _G.cp2, _G.cp3 }

    local res2 = m:revert_to_checkpoint(2, _G.checkpoints)
    _G.res2 = res2

    vim.wait(2000, function()
      local has_mer = _G.ensure_exists("dir0/mer.lua")
      local has_hello = _G.ensure_exists("dir2/dir3/hello.lua")
      local has_hello1 = _G.ensure_exists("dir2/dir3/hello1.lua")
      return has_mer and has_hello and (not has_hello1)
    end)

    _G.has_mer = _G.ensure_exists("dir0/mer.lua")
    _G.has_hello = _G.ensure_exists("dir2/dir3/hello.lua")
    _G.has_hello1 = _G.ensure_exists("dir2/dir3/hello1.lua")

  ]])

  -- h.eq(true, child.lua_get("_G.has_mer"), "mer.lua should be restored")
  h.eq(true, child.lua_get("_G.has_hello"), "hello.lua should be restored")
  h.eq(false, child.lua_get("_G.has_hello1"), "hello1.lua should be gone")

  child.lua([[
    -- Phase 2 had: hi->hi1 rename, hi1 delete, mer create
    -- Current state (after revert to CP2): mer exists, hi1 is deleted (from Phase 2), hi is gone (renamed in P2)
    -- Revert P2:
    -- mer created -> delete mer
    -- hi1 deleted -> restore hi1
    -- hi->hi1 renamed -> rename hi1 to hi

    local res1 = m:revert_to_checkpoint(1, _G.checkpoints)
    _G.res1 = res1

    vim.wait(2000, function()
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

    local res0 = m:revert_to_original(_G.checkpoints)

    vim.wait(2000, function()
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
  ]])

  h.eq(false, child.lua_get("_G.has_hi_orig"), "hi.lua should be deleted")
  h.eq(false, child.lua_get("_G.has_hello_orig"), "hello.lua should be deleted")
  h.eq(false, child.lua_get("_G.has_salute_orig"), "salute.lua should be deleted (restored then deleted)")
  h.eq(false, child.lua_get("_G.has_dir1"), "dir1 should be deleted (empty)")
  h.eq(false, child.lua_get("_G.has_dir2"), "dir2 should be deleted (empty)")
end

return T
