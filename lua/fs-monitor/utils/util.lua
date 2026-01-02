local M = {}

local TITLE = "Fs-Monitor"

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = TITLE })
end

function M.pluralize(count, word)
  if type(count) ~= "number" or type(word) ~= "string" then return word or "item" end
  return count == 1 and word or word .. "s"
end

return M
