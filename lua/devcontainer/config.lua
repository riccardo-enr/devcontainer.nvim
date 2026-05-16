--[[
Helpers for locating the devcontainer.json config and resolving the
effective workspace folder for CLI invocations.
]]

local M = {}

--- Return the configured workspace folder, falling back to cwd.
---@return string
function M.workspace_folder()
  local cfg = require("devcontainer").config
  return cfg.workspace_folder or vim.fn.getcwd()
end

--- Find a devcontainer.json under the workspace folder, if any.
---@return string?
function M.find_config()
  local root = M.workspace_folder()
  local candidates = {
    root .. "/.devcontainer/devcontainer.json",
    root .. "/.devcontainer.json",
  }
  for _, p in ipairs(candidates) do
    if vim.uv.fs_stat(p) then return p end
  end
  return nil
end

return M
