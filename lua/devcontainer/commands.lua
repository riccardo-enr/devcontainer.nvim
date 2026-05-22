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
  local selected = config.find_config()
  if selected and config.is_variant(selected) then
    table.insert(out, "--config")
    table.insert(out, selected)
  end
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

--- If multiple devcontainer.json candidates exist and the user has not
--- yet picked one this session, prompt via `vim.ui.select`. Calls `cb`
--- with true if work should proceed, false if the user cancelled.
---@param cb fun(ok: boolean)
local function ensure_variant(cb)
  if config.selected() then return cb(true) end
  local all = config.find_configs()
  if #all <= 1 then return cb(true) end

  local root = config.workspace_folder()
  local function label(p)
    local rel = p:sub(#root + 2)
    return rel
  end
  vim.ui.select(all, {
    prompt = "devcontainer variant:",
    format_item = label,
  }, function(choice)
    if not choice then
      notify("cancelled (no variant selected)", vim.log.levels.WARN)
      return cb(false)
    end
    config.set_selected(choice)
    notify("using " .. label(choice), vim.log.levels.INFO)
    cb(true)
  end)
end

function M.up()
  ensure_variant(function(ok)
    if not ok then return end
    require("devcontainer.container").up({})
  end)
end

function M.rebuild()
  ensure_variant(function(ok)
    if not ok then return end
    require("devcontainer.container").up({ rebuild = true })
  end)
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

--- Prompt the user to (re)select which devcontainer.json variant to use.
function M.pick_variant()
  local all = config.find_configs()
  if #all == 0 then
    notify("no devcontainer.json found under workspace", vim.log.levels.WARN)
    return
  end
  if #all == 1 then
    config.set_selected(all[1])
    notify("only one config: " .. all[1], vim.log.levels.INFO)
    return
  end
  local root = config.workspace_folder()
  vim.ui.select(all, {
    prompt = "devcontainer variant:",
    format_item = function(p) return p:sub(#root + 2) end,
  }, function(choice)
    if not choice then return end
    config.set_selected(choice)
    notify("using " .. choice:sub(#root + 2), vim.log.levels.INFO)
  end)
end

return M
