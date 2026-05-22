--[[
Helpers for locating the devcontainer.json config and resolving the
effective workspace folder for CLI invocations.

A workspace may contain multiple devcontainer.json files under
`.devcontainer/<variant>/devcontainer.json` (e.g. `cpu`, `gpu`). When
multiple are present, the user picks one via `:DevcontainerUp`; the
choice is cached per workspace for the rest of the session.
]]

local M = {}

local selected_by_ws = {}

--- Return the configured workspace folder, falling back to cwd.
---@return string
function M.workspace_folder()
  local cfg = require("devcontainer").config
  return cfg.workspace_folder or vim.fn.getcwd()
end

--- All candidate devcontainer.json paths under the workspace folder.
--- Order: canonical top-level paths first, then any
--- `.devcontainer/<subdir>/devcontainer.json` variants (alphabetical).
---@return string[]
function M.find_configs()
  local root = M.workspace_folder()
  local results = {}
  local seen = {}
  local function push(p)
    if p and not seen[p] and vim.uv.fs_stat(p) then
      seen[p] = true
      table.insert(results, p)
    end
  end

  push(root .. "/.devcontainer/devcontainer.json")
  push(root .. "/.devcontainer.json")

  local dc_dir = root .. "/.devcontainer"
  local fs = vim.uv.fs_scandir(dc_dir)
  if fs then
    local entries = {}
    while true do
      local name, t = vim.uv.fs_scandir_next(fs)
      if not name then break end
      if t == "directory" then table.insert(entries, name) end
    end
    table.sort(entries)
    for _, name in ipairs(entries) do
      push(dc_dir .. "/" .. name .. "/devcontainer.json")
    end
  end

  return results
end

--- Find a devcontainer.json under the workspace folder, if any.
--- Returns the user's session selection when set, the config override
--- when set, the canonical path when a single config exists, or the
--- first candidate otherwise. Returns nil when nothing is found.
---@return string?
function M.find_config()
  local ws = M.workspace_folder()
  if selected_by_ws[ws] and vim.uv.fs_stat(selected_by_ws[ws]) then
    return selected_by_ws[ws]
  end
  local cfg = require("devcontainer").config
  if cfg.config_path and vim.uv.fs_stat(cfg.config_path) then
    return cfg.config_path
  end
  local all = M.find_configs()
  return all[1]
end

--- Set the selected config path for the current workspace (session-only).
---@param path string?
function M.set_selected(path)
  selected_by_ws[M.workspace_folder()] = path
end

--- Get the session-selected config path for the current workspace.
---@return string?
function M.selected()
  return selected_by_ws[M.workspace_folder()]
end

--- True when this path is a non-canonical variant that must be passed
--- to the CLI via `--config`.
---@param path string
---@return boolean
function M.is_variant(path)
  local root = M.workspace_folder()
  if path == root .. "/.devcontainer/devcontainer.json" then return false end
  if path == root .. "/.devcontainer.json" then return false end
  return true
end

return M
