-- Debug logging helper
local log = {}
local fmt = string.format

function log:_write(level, msg, ...)
  local config = require("fs-monitor.config").options
  if config and config.debug then
    local prefix = fmt("[fs-monitor:%s] ", level)
    local log_msg = fmt(prefix .. msg, ...) .. "\n"
    local log_path = config.debug_file or (vim.fn.stdpath("state") .. "/fs-monitor.log")
    vim.uv.fs_open(log_path, "a", 438, function(err, fd)
      if err then return end
      vim.uv.fs_write(fd, log_msg, nil, function()
        vim.uv.fs_close(fd)
      end)
    end)
  end
end

function log:debug(msg, ...)
  self:_write("debug", msg, ...)
end

function log:info(msg, ...)
  self:_write("info", msg, ...)
end

function log:warn(msg, ...)
  self:_write("warn", msg, ...)
end

function log:trace(msg, ...)
  self:_write("trace", msg, ...)
end

return log
