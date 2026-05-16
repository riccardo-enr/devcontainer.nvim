--[[
User-facing command handlers. Lifecycle commands (`up`, `rebuild`, `status`)
route through the async `container` module; interactive commands (`exec`,
`shell`) still use a terminal split since they need a TTY.
]]

local config = require("devcontainer.config")

local M = {}

local function notify(msg, level)
  vim.notify("devcontainer.nvim: " .. msg, level)
end

local function exec_argv(sub)
  local cfg = require("devcontainer").config
  local out = { cfg.cli }
  vim.list_extend(out, sub)
  table.insert(out, "--workspace-folder")
  table.insert(out, config.workspace_folder())
  return out
end

local function run_term(cmd)
  vim.cmd("botright new")
  vim.bo.bufhidden = "wipe"
  vim.fn.termopen(cmd)
  if not require("devcontainer").config.auto_attach then
    vim.cmd("wincmd p")
  end
end

function M.up()
  require("devcontainer.container").up({})
end

function M.rebuild()
  require("devcontainer.container").up({ rebuild = true })
end

function M.status()
  require("devcontainer.container").status({
    on_exit = function(state, err)
      if err or not state.running then
        notify("stopped" .. (err and (" (" .. err .. ")") or ""), vim.log.levels.WARN)
        return
      end
      local short = (state.container_id or ""):sub(1, 12)
      notify("running: " .. short .. " ws=" .. (state.remote_workspace_folder or "?"),
        vim.log.levels.INFO)
    end,
  })
end

---@param command string
function M.exec(command)
  if command == nil or command == "" then
    notify(":DevcontainerExec requires a command", vim.log.levels.ERROR)
    return
  end
  local cmd = exec_argv({ "exec" })
  vim.list_extend(cmd, { "sh", "-lc", command })
  run_term(cmd)
end

function M.shell()
  local cmd = exec_argv({ "exec" })
  vim.list_extend(cmd, { "sh", "-l" })
  run_term(cmd)
end

function M.log()
  require("devcontainer.buffer").open()
end

function M.down()
  notify("down is not implemented yet", vim.log.levels.WARN)
end

return M
