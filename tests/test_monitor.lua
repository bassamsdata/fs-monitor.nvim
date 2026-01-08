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

        _G.create_monitor = function(opts)
          return Monitor.new(opts)
        end

        _G.file_operations = { writes = {}, deletes = {}, renames = {} }

        local fs = require("fs-monitor.utils.fs")
        local original_write = fs.write_file
        local original_delete = fs.delete_file
        local original_rename = fs.rename_file

        fs.write_file = function(path, content)
          table.insert(_G.file_operations.writes, { path = path, content = content })
          return true
        end

        fs.delete_file = function(path)
          table.insert(_G.file_operations.deletes, { path = path })
          return true
        end

        fs.rename_file = function(old_path, new_path)
          table.insert(_G.file_operations.renames, { old_path = old_path, new_path = new_path })
          return true
        end

        _G.reset_file_operations = function()
          _G.file_operations = { writes = {}, deletes = {}, renames = {} }
        end

        _G.restore_fs_functions = function()
          fs.write_file = original_write
          fs.delete_file = original_delete
          fs.rename_file = original_rename
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

T["Monitor"] = new_set()

T["Monitor"]["respects ignore patterns"] = function()
  child.lua([[
    local m = Monitor.new({ ignore_patterns = { "%.ignore$" } })

    -- Test built-in ignores
    _G.git = m:_should_ignore_file(".git/config")
    _G.node = m:_should_ignore_file("node_modules/package.json")

    -- Test custom ignores
    _G.ignored = m:_should_ignore_file("file.ignore")
    _G.not_ignored = m:_should_ignore_file("file.txt")
  ]])

  h.eq(true, child.lua_get("_G.git"))
  h.eq(true, child.lua_get("_G.node"))
  h.eq(true, child.lua_get("_G.ignored"))
  h.eq(false, child.lua_get("_G.not_ignored"))
end

T["Monitor"]["parses gitignore correctly"] = function()
  child.lua([=[
    local path = vim.fs.joinpath(_G.TEST_DIR, ".gitignore")
    local f = io.open(path, "w")
    f:write([[
*.log
/dist/
!important.log
]])
    f:close()

    local m = Monitor.new({ respect_gitignore = true })
    m:_load_gitignore(_G.TEST_DIR)

    _G.patterns = m.ignore_patterns
    _G.loaded = m.gitignore_loaded
    _G.test_dir = _G.TEST_DIR

    _G.log = m:_should_ignore_file("test.log")
    _G.dist = m:_should_ignore_file("dist/bundle.js")
    _G.important = m:_should_ignore_file("important.log")
    _G.other = m:_should_ignore_file("other.txt")
  ]=])

  h.eq(true, child.lua_get("_G.log"))
  h.eq(true, child.lua_get("_G.dist"))
  h.eq(false, child.lua_get("_G.important"))
  h.eq(false, child.lua_get("_G.other"))
end

T["Monitor"]["detects binary files"] = function()
  child.lua([[
    local m = Monitor.new()

    -- Create binary file
    local path = vim.fs.joinpath(_G.TEST_DIR, "binary.bin")
    local f = io.open(path, "w")
    f:write("binary\0data")
    f:close()

    _G.done = false
    m:_read_file_async(path, function(content, err)
      _G.content = content
      _G.err = err
      _G.done = true
    end)
  ]])

  child.wait(500, "_G.done == true")
  h.eq("Binary file", child.lua_get("_G.err"))
end

T["Monitor"]["Revert"] = new_set()

T["Monitor"]["Revert"]["reverts file creation by deleting file"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    -- Simulate: Checkpoint 1 (empty), then file created
    m.changes = {
      { path = "new_file.txt", kind = "created", new_content = "content", timestamp = 200, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 100, change_count = 0, label = "Initial" },
      { timestamp = 300, change_count = 1, label = "Current" },
    }

    local result = m:revert_to_checkpoint(1, checkpoints)
    _G.result = result
  ]])

  h.eq(1, child.lua_get("#_G.file_operations.deletes"))
  h.expect_contains("new_file.txt", child.lua_get("_G.file_operations.deletes[1].path"))
  h.eq(0, child.lua_get("#_G.result.new_changes"))
end

T["Monitor"]["Revert"]["reverts file modification by restoring old content"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    -- Simulate: Original file existed, then modified
    m.changes = {
      { path = "existing.txt", kind = "modified", old_content = "original content", new_content = "modified content", timestamp = 200, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 100, change_count = 0, label = "Initial" },
      { timestamp = 300, change_count = 1, label = "Current" },
    }

    local result = m:revert_to_checkpoint(1, checkpoints)
    _G.result = result
  ]])

  h.eq(1, child.lua_get("#_G.file_operations.writes"))
  h.eq("original content", child.lua_get("_G.file_operations.writes[1].content"))
  h.eq(0, child.lua_get("#_G.result.new_changes"))
end

T["Monitor"]["Revert"]["reverts file deletion by recreating file"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    -- Simulate: File existed, then deleted
    m.changes = {
      { path = "deleted.txt", kind = "deleted", old_content = "was here", timestamp = 200, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 100, change_count = 0, label = "Initial" },
      { timestamp = 300, change_count = 1, label = "Current" },
    }

    local result = m:revert_to_checkpoint(1, checkpoints)
    _G.result = result
  ]])

  h.eq(1, child.lua_get("#_G.file_operations.writes"))
  h.eq("was here", child.lua_get("_G.file_operations.writes[1].content"))
  h.eq(0, child.lua_get("#_G.result.new_changes"))
end

T["Monitor"]["Revert"]["reverts to middle checkpoint keeping earlier changes"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    -- Simulate: File created at checkpoint 1, modified at checkpoint 2
    m.changes = {
      { path = "file.txt", kind = "created", new_content = "initial", timestamp = 100, tool_name = "workspace", metadata = {} },
      { path = "file.txt", kind = "modified", old_content = "initial", new_content = "modified", timestamp = 300, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 200, change_count = 1, label = "Checkpoint 1" },
      { timestamp = 400, change_count = 2, label = "Checkpoint 2" },
    }

    -- Revert to checkpoint 1 should undo the modification but keep creation
    local result = m:revert_to_checkpoint(1, checkpoints)
    _G.result = result
  ]])

  h.eq(1, child.lua_get("#_G.file_operations.writes"))
  h.eq("initial", child.lua_get("_G.file_operations.writes[1].content"))
  h.eq(1, child.lua_get("#_G.result.new_changes"))
  h.eq("created", child.lua_get("_G.result.new_changes[1].kind"))
end

T["Monitor"]["Revert"]["does nothing when reverting to final checkpoint"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    m.changes = {
      { path = "file.txt", kind = "modified", old_content = "old", new_content = "new", timestamp = 100, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 200, change_count = 1, label = "Final" },
    }

    local result = m:revert_to_checkpoint(1, checkpoints)
    _G.result = result
  ]])

  h.eq(vim.NIL, child.lua_get("_G.result"))
  h.eq(0, child.lua_get("#_G.file_operations.writes"))
  h.eq(0, child.lua_get("#_G.file_operations.deletes"))
end

T["Monitor"]["Revert"]["handles multiple files correctly"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    -- Simulate multiple files modified after checkpoint
    m.changes = {
      { path = "file_a.txt", kind = "created", new_content = "a content", timestamp = 50, tool_name = "workspace", metadata = {} },
      { path = "file_b.txt", kind = "created", new_content = "b content", timestamp = 200, tool_name = "workspace", metadata = {} },
      { path = "file_c.txt", kind = "modified", old_content = "c original", new_content = "c modified", timestamp = 250, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 100, change_count = 1, label = "Checkpoint 1" },
      { timestamp = 300, change_count = 3, label = "Checkpoint 2" },
    }

    -- Revert to checkpoint 1 should undo file_b creation and file_c modification
    local result = m:revert_to_checkpoint(1, checkpoints)
    _G.result = result
    _G.num_writes = #_G.file_operations.writes
    _G.num_deletes = #_G.file_operations.deletes
  ]])

  -- file_b should be deleted, file_c should be restored
  h.eq(1, child.lua_get("_G.num_deletes"))
  h.eq(1, child.lua_get("_G.num_writes"))
  h.eq(1, child.lua_get("#_G.result.new_changes"))
end

T["Monitor"]["Revert"]["revert_to_original clears all changes"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    m.changes = {
      { path = "file1.txt", kind = "created", new_content = "new", timestamp = 100, tool_name = "workspace", metadata = {} },
      { path = "file2.txt", kind = "modified", old_content = "old", new_content = "modified", timestamp = 200, tool_name = "workspace", metadata = {} },
      { path = "file3.txt", kind = "deleted", old_content = "was here", timestamp = 300, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 150, change_count = 1, label = "Checkpoint 1" },
      { timestamp = 350, change_count = 3, label = "Checkpoint 2" },
    }

    local result = m:revert_to_original(checkpoints)
    _G.result = result
    _G.remaining_changes = #m.changes
  ]])

  h.eq(0, child.lua_get("_G.remaining_changes"))
  h.eq(0, child.lua_get("#_G.result.new_changes"))
  h.eq(0, child.lua_get("#_G.result.new_checkpoints"))
  h.eq(true, child.lua_get("_G.result.is_full_revert"))
end

T["Monitor"]["Revert"]["handles create-modify-delete sequence"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    -- Complex lifecycle: file created, modified, then deleted
    m.changes = {
      { path = "lifecycle.txt", kind = "created", new_content = "initial", timestamp = 100, tool_name = "workspace", metadata = {} },
      { path = "lifecycle.txt", kind = "modified", old_content = "initial", new_content = "modified", timestamp = 200, tool_name = "workspace", metadata = {} },
      { path = "lifecycle.txt", kind = "deleted", old_content = "modified", timestamp = 300, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 50, change_count = 0, label = "Initial" },
      { timestamp = 350, change_count = 3, label = "Current" },
    }

    -- Revert to initial: first change was "created" with no old_content
    -- The file should be deleted since it didn't exist before
    local result = m:revert_to_original(checkpoints)
    _G.result = result
  ]])

  -- Created file with no old_content means delete it
  h.eq(1, child.lua_get("#_G.file_operations.deletes"))
  h.eq(0, child.lua_get("#_G.result.new_changes"))
end

T["Monitor"]["Revert"]["preserves checkpoint indices correctly"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    m.changes = {
      { path = "f1.txt", kind = "created", new_content = "1", timestamp = 100, tool_name = "workspace", metadata = {} },
      { path = "f2.txt", kind = "created", new_content = "2", timestamp = 200, tool_name = "workspace", metadata = {} },
      { path = "f3.txt", kind = "created", new_content = "3", timestamp = 300, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 150, change_count = 1, label = "CP1" },
      { timestamp = 250, change_count = 2, label = "CP2" },
      { timestamp = 350, change_count = 3, label = "CP3" },
    }

    -- Revert to checkpoint 2
    local result = m:revert_to_checkpoint(2, checkpoints)
    _G.result = result
    _G.num_new_checkpoints = #result.new_checkpoints
  ]])

  -- Should keep checkpoints 1 and 2, remove 3
  h.eq(2, child.lua_get("_G.num_new_checkpoints"))
  h.eq("CP1", child.lua_get("_G.result.new_checkpoints[1].label"))
  h.eq("CP2", child.lua_get("_G.result.new_checkpoints[2].label"))
end

T["Monitor"]["Revert"]["handles revert with no changes to revert"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    -- All changes are before the checkpoint
    m.changes = {
      { path = "old.txt", kind = "created", new_content = "old", timestamp = 50, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 100, change_count = 1, label = "Checkpoint 1" },
    }

    -- Revert to checkpoint 1 - no changes after it
    local result = m:revert_to_checkpoint(1, checkpoints)
    _G.result = result
  ]])

  h.eq(vim.NIL, child.lua_get("_G.result"))
end

T["Monitor"]["Revert"]["returns nil for invalid checkpoint index"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    m.changes = {
      { path = "file.txt", kind = "created", new_content = "new", timestamp = 100, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 200, change_count = 1, label = "CP1" },
    }

    _G.result_negative = m:revert_to_checkpoint(-1, checkpoints)
    _G.result_zero = m:revert_to_checkpoint(0, checkpoints)
    _G.result_too_high = m:revert_to_checkpoint(5, checkpoints)
  ]])

  h.eq(vim.NIL, child.lua_get("_G.result_negative"))
  h.eq(vim.NIL, child.lua_get("_G.result_zero"))
  h.eq(vim.NIL, child.lua_get("_G.result_too_high"))
end

T["Monitor"]["Revert"]["handles empty checkpoints list"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    m.changes = {
      { path = "file.txt", kind = "created", new_content = "new", timestamp = 100, tool_name = "workspace", metadata = {} },
    }

    local result = m:revert_to_checkpoint(1, {})
    _G.result = result
  ]])

  h.eq(vim.NIL, child.lua_get("_G.result"))
end

T["Monitor"]["Revert"]["handles transient files (created then deleted)"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    -- Simulate: File created and then deleted (transient)
    m.changes = {
      { path = "temp.txt", kind = "created", new_content = "temp content", timestamp = 100, tool_name = "workspace", metadata = {} },
      { path = "temp.txt", kind = "deleted", old_content = "temp content", timestamp = 200, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 150, change_count = 1, label = "After create" },
      { timestamp = 250, change_count = 2, label = "After delete" },
    }

    -- Revert to original (undo everything)
    local result = m:revert_to_original(checkpoints)
    _G.result = result
  ]])

  local result = child.lua_get("_G.result")
  h.expect_not_nil(result, "revert_to_original should return result")
  h.eq(2, result.reverted_count, "should revert both changes")
  h.eq(0, result.error_count, "should have no errors")

  local writes = child.lua_get("_G.file_operations.writes")
  local deletes = child.lua_get("_G.file_operations.deletes")

  -- Reverting deleted → writes file, reverting created → deletes file
  h.eq(1, #writes, "should write once (restore deleted file)")
  h.eq(1, #deletes, "should delete once (undo creation)")
  h.expect_contains("temp.txt", writes[1].path, "should restore temp.txt")
  h.expect_contains("temp.txt", deletes[1].path, "should delete temp.txt")
end

T["Monitor"]["Revert"]["handles multiple transient files"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    -- Simulate: Multiple temp files created and deleted
    m.changes = {
      { path = "temp1.txt", kind = "created", new_content = "temp1", timestamp = 100, tool_name = "workspace", metadata = {} },
      { path = "temp2.txt", kind = "created", new_content = "temp2", timestamp = 150, tool_name = "workspace", metadata = {} },
      { path = "temp1.txt", kind = "deleted", old_content = "temp1", timestamp = 200, tool_name = "workspace", metadata = {} },
      { path = "temp2.txt", kind = "deleted", old_content = "temp2", timestamp = 250, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 300, change_count = 4, label = "All done" },
    }

    local result = m:revert_to_original(checkpoints)
    _G.result = result
  ]])

  local result = child.lua_get("_G.result")
  h.eq(4, result.reverted_count, "should revert all 4 changes")

  local writes = child.lua_get("_G.file_operations.writes")
  local deletes = child.lua_get("_G.file_operations.deletes")

  h.eq(2, #writes, "should restore both deleted files")
  h.eq(2, #deletes, "should delete both created files")
end

T["Monitor"]["Revert"]["transient with checkpoint between create and delete"] = function()
  child.lua([[
    _G.reset_file_operations()
    local m = Monitor.new()

    -- Simulate: File created at CP1, deleted at CP2
    m.changes = {
      { path = "temp.txt", kind = "created", new_content = "content", timestamp = 100, tool_name = "workspace", metadata = {} },
      { path = "temp.txt", kind = "deleted", old_content = "content", timestamp = 300, tool_name = "workspace", metadata = {} },
    }

    local checkpoints = {
      { timestamp = 200, change_count = 1, label = "After create" },
      { timestamp = 400, change_count = 2, label = "After delete" },
    }

    -- Revert to CP1 (undo deletion only)
    local result = m:revert_to_checkpoint(1, checkpoints)
    _G.result = result
  ]])

  local result = child.lua_get("_G.result")
  h.eq(1, result.reverted_count, "should revert only the deletion")

  local writes = child.lua_get("_G.file_operations.writes")
  local deletes = child.lua_get("_G.file_operations.deletes")

  h.eq(1, #writes, "should restore the deleted file")
  h.eq(0, #deletes, "should not delete anything yet")
  h.expect_contains("temp.txt", writes[1].path, "should restore temp.txt")
end

T["Monitor"]["Checkpoint"] = new_set()

T["Monitor"]["Checkpoint"]["creates checkpoint with correct fields"] = function()
  child.lua([[
    local m = Monitor.new()
    m.changes = {
      { path = "a.txt", kind = "created", timestamp = 100 },
      { path = "b.txt", kind = "modified", timestamp = 200 },
    }

    _G.checkpoint = m:create_checkpoint()
  ]])

  local checkpoint = child.lua_get("_G.checkpoint")
  h.expect_not_nil(checkpoint.timestamp, "Checkpoint should have timestamp")
  h.eq(2, checkpoint.change_count)
end

T["Monitor"]["Checkpoint"]["get_changes_since_checkpoint returns correct changes"] = function()
  child.lua([[
    local m = Monitor.new()
    m.changes = {
      { path = "a.txt", kind = "created", timestamp = 100 },
      { path = "b.txt", kind = "modified", timestamp = 200 },
      { path = "c.txt", kind = "deleted", timestamp = 300 },
    }

    local checkpoint = { timestamp = 150, change_count = 1 }
    _G.since = m:get_changes_since_checkpoint(checkpoint)
  ]])

  local since = child.lua_get("_G.since")
  h.eq(2, #since)
  h.eq("b.txt", since[1].path)
  h.eq("c.txt", since[2].path)
end

T["Monitor"]["Stats"] = new_set()

T["Monitor"]["Stats"]["returns correct statistics"] = function()
  child.lua([[
    local m = Monitor.new()
    m.changes = {
      { path = "new.txt", kind = "created", tool_name = "tool_a" },
      { path = "mod1.txt", kind = "modified", tool_name = "tool_a" },
      { path = "mod2.txt", kind = "modified", tool_name = "tool_b" },
      { path = "del.txt", kind = "deleted", tool_name = "tool_b" },
      { path = "renamed.txt", kind = "renamed", tool_name = "tool_c" },
    }

    _G.stats = m:get_stats()
  ]])

  local stats = child.lua_get("_G.stats")
  h.eq(5, stats.total_changes)
  h.eq(1, stats.created)
  h.eq(2, stats.modified)
  h.eq(1, stats.deleted)
  h.eq(1, stats.renamed)
  h.eq(3, #stats.tools)
end

T["Monitor"]["set_changes"] = new_set()

T["Monitor"]["set_changes"]["replaces changes list"] = function()
  child.lua([[
    local m = Monitor.new()
    m.changes = {
      { path = "old.txt", kind = "created" },
    }

    local new_changes = {
      { path = "new1.txt", kind = "modified" },
      { path = "new2.txt", kind = "deleted" },
    }

    m:set_changes(new_changes)
    _G.changes = m.changes
  ]])

  local changes = child.lua_get("_G.changes")
  h.eq(2, #changes)
  h.eq("new1.txt", changes[1].path)
  h.eq("new2.txt", changes[2].path)
end

return T
