local M = {}

local TITLE = "Fs-Monitor"

---@param msg string
---@param level? number
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = TITLE })
end

---@param count number
---@param word string
---@return string
function M.pluralize(count, word)
  if type(count) ~= "number" or type(word) ~= "string" then return word or "item" end
  return count == 1 and word or word .. "s"
end

return M
