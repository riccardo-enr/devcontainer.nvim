--[[
Thin wrappers around the `devcontainer` CLI. Each command shells out to
the CLI binary configured in `require("devcontainer").config.cli` and
streams output into a scratch terminal buffer.
]]

local config = require("devcontainer.config")

local M = {}

--- Build the base argv with the shared --workspace-folder flag.
---@param sub string[]
---@return string[]
local function argv(sub)
  local cfg = require("devcontainer").config
  local out = { cfg.cli }
  vim.list_extend(out, sub)
  table.insert(out, "--workspace-folder")
  table.insert(out, config.workspace_folder())
  return out
end

--- Run an argv in a new terminal split.
---@param cmd string[]
local function run_term(cmd)
  vim.cmd("botright new")
  vim.bo.bufhidden = "wipe"
  vim.fn.termopen(cmd)
  if not require("devcontainer").config.auto_attach then
    vim.cmd("wincmd p")
  end
end

function M.up()
  run_term(argv({ "up" }))
end

function M.down()
  -- The CLI does not (yet) have a first-class "down"; emulate it via docker.
  local cfg_path = config.find_config()
  if not cfg_path then
    vim.notify("devcontainer.nvim: no devcontainer.json found", vim.log.levels.WARN)
    return
  end
  vim.notify("devcontainer.nvim: down is not implemented yet", vim.log.levels.WARN)
end

function M.rebuild()
  run_term(argv({ "up", "--remove-existing-container", "--build-no-cache" }))
end

---@param command string
function M.exec(command)
  if command == nil or command == "" then
    vim.notify("devcontainer.nvim: :DevcontainerExec requires a command", vim.log.levels.ERROR)
    return
  end
  local cmd = argv({ "exec" })
  -- Pass the user command as a single shell invocation so quoting works.
  vim.list_extend(cmd, { "sh", "-lc", command })
  run_term(cmd)
end

function M.shell()
  local cmd = argv({ "exec" })
  vim.list_extend(cmd, { "sh", "-l" })
  run_term(cmd)
end

function M.status()
  local cfg_path = config.find_config()
  if cfg_path then
    vim.notify("devcontainer.nvim: config -> " .. cfg_path, vim.log.levels.INFO)
  else
    vim.notify("devcontainer.nvim: no devcontainer.json found under " .. config.workspace_folder(), vim.log.levels.WARN)
  end
end

return M
