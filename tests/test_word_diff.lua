local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        WordDiff = require("fs-monitor.diff.word_diff")
        Hunks = require("fs-monitor.diff.hunks")
        Render = require("fs-monitor.diff.render")

        _G.api = vim.api
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

T["Word Diff"] = new_set()

T["Word Diff"]["split_words returns correct byte positions"] = function()
  child.lua([[
    local split_words = function(str)
      if str == "" then return {} end

      local words = {}
      local word_chars = {}
      local word_start_byte = nil
      local current_byte = 0

      local starts = vim.str_utf_pos(str)

      local function flush_word()
        if #word_chars > 0 then
          local word_text = table.concat(word_chars)
          words[#words + 1] = {
            word = word_text,
            start_col = word_start_byte,
            end_col = current_byte,
          }
          word_chars = {}
          word_start_byte = nil
        end
      end

      for idx, utf_start in ipairs(starts) do
        local utf_stop = (starts[idx + 1] or (#str + 1)) - 1
        local ch = str:sub(utf_start, utf_stop)
        local ch_len = #ch

        if vim.fn.charclass(ch) == 2 then
          if word_start_byte == nil then word_start_byte = current_byte end
          word_chars[#word_chars + 1] = ch
        else
          flush_word()
          words[#words + 1] = {
            word = ch,
            start_col = current_byte,
            end_col = current_byte + ch_len,
          }
        end

        current_byte = current_byte + ch_len
      end

      flush_word()
      return words
    end

    _G.test_simple = split_words("hello world")
    _G.test_code = split_words("const oldValue = 42;")
  ]])

  local simple = child.lua_get("_G.test_simple")
  h.eq(3, #simple)
  h.eq("hello", simple[1].word)
  h.eq(0, simple[1].start_col)
  h.eq(5, simple[1].end_col)
  h.eq(" ", simple[2].word)
  h.eq(5, simple[2].start_col)
  h.eq(6, simple[2].end_col)
  h.eq("world", simple[3].word)
  h.eq(6, simple[3].start_col)
  h.eq(11, simple[3].end_col)

  local code = child.lua_get("_G.test_code")
  h.eq("const", code[1].word)
  h.eq("oldValue", code[3].word)
end

T["Word Diff"]["calculates word diffs for matching line counts"] = function()
  child.lua([[
    local hunk = {
      removed_lines = { "const oldValue = 42;" },
      added_lines = { "const newValue = 42;" },
      original_start = 1,
      original_count = 1,
      updated_start = 1,
      updated_count = 1,
      context_before = {},
      context_after = {},
    }

    _G.word_diffs = WordDiff._calculate_word_diffs(hunk)
  ]])

  local word_diffs = child.lua_get("_G.word_diffs")
  h.expect_not_nil(word_diffs, "Should return word diffs for matching line counts")
  h.expect_not_nil(word_diffs[1], "Should have diff for first line")
  h.expect_gt(#word_diffs[1].old_ranges, 0, "Should have old ranges")
  h.expect_gt(#word_diffs[1].new_ranges, 0, "Should have new ranges")
end

T["Word Diff"]["returns nil when too many lines"] = function()
  child.lua([[
    local hunk = {
      removed_lines = { "a", "b", "c", "d", "e", "f" },
      added_lines = { "1", "2", "3", "4", "5", "6" },
      original_start = 1,
      original_count = 6,
      updated_start = 1,
      updated_count = 6,
      context_before = {},
      context_after = {},
    }

    _G.word_diffs = WordDiff._calculate_word_diffs(hunk)
  ]])

  local word_diffs = child.lua_get("_G.word_diffs")
  h.eq(vim.NIL, word_diffs)
end

T["Word Diff"]["apply_word_highlights adds correct extmarks"] = function()
  child.lua([[
    local bufnr = api.nvim_create_buf(false, true)
    local ns_id = api.nvim_create_namespace("test_word_diff")

    local old_lines = {
      "local function test()",
      "  print('hello world')",
      "  return true",
      "  -- end of function",
    }
    local new_lines = {
      "local function check()",
      "  print('goodbye world')",
      "  return false",
      "  -- end of function",
    }

    local hunk = {
      removed_lines = old_lines,
      added_lines = new_lines,
      original_start = 1,
      original_count = 4,
      updated_start = 1,
      updated_count = 4,
      context_before = {},
      context_after = {},
    }

    Render.render_diff({
      buf = bufnr,
      ns = ns_id,
      hunks = { hunk },
      word_diff = true,
    })

    _G.test_buf = bufnr
    _G.test_ns = ns_id
  ]])

  local marks = child.lua_get("api.nvim_buf_get_extmarks(_G.test_buf, _G.test_ns, 0, -1, { details = true })")

  local word_marks = {}
  for _, mark in ipairs(marks) do
    if mark[4].hl_group == "FSMonitorDeleteWord" or mark[4].hl_group == "FSMonitorAddWord" then
      table.insert(word_marks, mark)
    end
  end

  -- We expect:
  -- 1. test -> check (2 marks)
  -- 2. hello -> goodbye (2 marks)
  -- 3. true -> false (2 marks)
  -- 4. end of function -> end of function (0 word marks, they are equal)
  h.eq(6, #word_marks)

  -- Check first line change: test -> check
  -- Line 1 is removed "local function test()"
  -- Line 5 is added "local function check()"
  local found_test = false
  local found_check = false

  for _, mark in ipairs(word_marks) do
    local line = mark[2]
    local start_col = mark[3]
    local end_col = mark[4].end_col
    local hl = mark[4].hl_group

    if line == 1 and hl == "FSMonitorDeleteWord" and start_col == 15 and end_col == 19 then
      found_test = true
    elseif line == 5 and hl == "FSMonitorAddWord" and start_col == 15 and end_col == 20 then
      found_check = true
    end
  end

  h.expect_true(found_test, "Should find 'test' deletion highlight")
  h.expect_true(found_check, "Should find 'check' addition highlight")
end

T["Word Diff"]["no word highlights when line counts differ in hunk"] = function()
  child.lua([[
    local bufnr = api.nvim_create_buf(false, true)
    local ns_id = api.nvim_create_namespace("test_word_diff_lines")

    local hunk = {
      removed_lines = { "local a = 1", "local b = 2" },
      added_lines = { "local c = 3" },
      original_start = 1,
      original_count = 2,
      updated_start = 1,
      updated_count = 1,
      context_before = {},
      context_after = {},
    }

    Render.render_diff({
      buf = bufnr,
      ns = ns_id,
      hunks = { hunk },
      word_diff = true,
    })

    _G.test_buf = bufnr
    _G.test_ns = ns_id
  ]])

  local marks = child.lua_get("api.nvim_buf_get_extmarks(_G.test_buf, _G.test_ns, 0, -1, { details = true })")
  local has_word_hl = false
  for _, mark in ipairs(marks) do
    local hl = mark[4].hl_group
    if hl == "FSMonitorDeleteWord" or hl == "FSMonitorAddWord" then
      has_word_hl = true
      break
    end
  end

  h.expect_false(has_word_hl, "Should not apply word highlights when line counts differ")
end

return T
