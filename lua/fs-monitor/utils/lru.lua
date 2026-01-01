---@class FSMonitor.LRUCache
---@field entries table<string, string> Path -> content
---@field access_order string[] Most recently accessed paths (newest at end)
---@field total_bytes number Current total bytes in cache
---@field max_bytes number Maximum bytes allowed

local M = {}

---Create a new LRU cache
---@param max_bytes number
---@return FSMonitor.LRUCache
function M.create(max_bytes)
  return {
    entries = {},
    access_order = {},
    total_bytes = 0,
    max_bytes = max_bytes,
  }
end

---Get an entry from LRU cache (updates access order)
---@param cache FSMonitor.LRUCache
---@param path string
---@return string|nil content
function M.get(cache, path)
  local content = cache.entries[path]
  if content then
    for i, p in ipairs(cache.access_order) do
      if p == path then
        table.remove(cache.access_order, i)
        break
      end
    end
    table.insert(cache.access_order, path)
  end
  return content
end

---Set an entry in LRU cache (evicts old entries if needed)
---@param cache FSMonitor.LRUCache
---@param path string
---@param content string
function M.set(cache, path, content)
  local content_size = #content

  if content_size > cache.max_bytes then return end

  local existing = cache.entries[path]
  if existing then
    cache.total_bytes = cache.total_bytes - #existing
    for i, p in ipairs(cache.access_order) do
      if p == path then
        table.remove(cache.access_order, i)
        break
      end
    end
  end

  while cache.total_bytes + content_size > cache.max_bytes and #cache.access_order > 0 do
    local oldest_path = table.remove(cache.access_order, 1)
    local oldest_content = cache.entries[oldest_path]
    if oldest_content then
      cache.total_bytes = cache.total_bytes - #oldest_content
      cache.entries[oldest_path] = nil
    end
  end

  cache.entries[path] = content
  cache.total_bytes = cache.total_bytes + content_size
  table.insert(cache.access_order, path)
end

---Remove an entry from LRU cache
---@param cache FSMonitor.LRUCache
---@param path string
function M.remove(cache, path)
  local content = cache.entries[path]
  if content then
    cache.total_bytes = cache.total_bytes - #content
    cache.entries[path] = nil
    for i, p in ipairs(cache.access_order) do
      if p == path then
        table.remove(cache.access_order, i)
        break
      end
    end
  end
end

---Clear the LRU cache
---@param cache FSMonitor.LRUCache
function M.clear(cache)
  cache.entries = {}
  cache.access_order = {}
  cache.total_bytes = 0
end

return M
