---@module "fs-monitor.types"

---@class FSMonitor.ViewerModule
local M = {}

---Main entry point for the diff viewer
---@param changes FSMonitor.Change[]
---@param checkpoints? FSMonitor.Checkpoint[]
---@param opts? { fs_monitor?: FSMonitor.Monitor, on_revert?: fun(changes: FSMonitor.Change[], checkpoints: FSMonitor.Checkpoint[]) }
---@return FSMonitor.Viewer|nil
function M.show(changes, checkpoints, opts)
  if not changes or #changes == 0 then
    require("fs-monitor.utils.util").notify("No file changes to display")
    return
  end

  local Viewer = require("fs-monitor.viewer.viewer")
  local viewer = Viewer.new(changes, checkpoints, opts)
  return viewer:show()
end

return M
