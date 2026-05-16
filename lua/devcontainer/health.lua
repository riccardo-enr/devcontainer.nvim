--[=[
`:checkhealth devcontainer` -- validates that the host has the pieces needed
to run a [[devcontainer]] from this plugin:

  1. the `devcontainer` CLI on $PATH (with version probe)
  2. a container runtime (docker OR podman; see ADR-0002)
  3. a parseable `.devcontainer/devcontainer.json` for the workspace

Each failure mode produces a distinct, actionable message. The runtime probe
is opportunistic and emits a warning (not an error) when neither runtime is
found, since the plugin is otherwise runtime-agnostic.
]=]

local M = {}

local CLI_INSTALL_HINT = "install with `npm install -g @devcontainers/cli`"

local function health()
  return vim.health
end

--- Run `argv` synchronously with a timeout, returning the result table or
--- nil on timeout.
---@param argv string[]
---@param timeout_ms integer
---@return table?
local function run_sync(argv, timeout_ms)
  local ok, proc = pcall(vim.system, argv, { text = true })
  if not ok or not proc then return nil end
  local res = proc:wait(timeout_ms)
  if not res then return nil end
  if (res.signal or 0) ~= 0 then return nil end
  return res
end

local function check_cli()
  local h = health()
  local cli = (require("devcontainer").config or {}).cli or "devcontainer"
  if vim.fn.executable(cli) ~= 1 then
    h.error("`" .. cli .. "` CLI not found on $PATH. " .. CLI_INSTALL_HINT .. ".")
    return
  end
  local res = run_sync({ cli, "--version" }, 2000)
  if not res then
    h.warn("`" .. cli .. " --version` timed out after 2s")
    return
  end
  if res.code ~= 0 then
    h.warn("`" .. cli .. " --version` exited " .. tostring(res.code) .. ": " .. (res.stderr or ""))
    return
  end
  local version = (res.stdout or ""):gsub("%s+$", "")
  h.ok("devcontainer CLI " .. version)
end

local function check_runtime()
  local h = health()
  local docker_present = vim.fn.executable("docker") == 1
  local podman_present = vim.fn.executable("podman") == 1
  if not docker_present and not podman_present then
    h.warn("no container runtime found. install docker or podman.")
    return
  end
  if docker_present then
    local res = run_sync({ "docker", "info" }, 1500)
    if res and res.code == 0 then
      h.ok("container runtime: docker (daemon reachable)")
      return
    end
  end
  if podman_present then
    local res = run_sync({ "podman", "info" }, 1500)
    if res and res.code == 0 then
      h.ok("container runtime: podman (daemon reachable)")
      return
    end
  end
  h.warn("container runtime present but `info` failed; daemon may be down. install or start docker or podman.")
end

local function check_config()
  local h = health()
  local cfg_mod = require("devcontainer.config")
  local path = cfg_mod.find_config()
  if not path then
    h.error("no devcontainer.json. create `.devcontainer/devcontainer.json` in the workspace.")
    return
  end
  local parsed, err = require("devcontainer.json").parse(path)
  if not parsed then
    h.error("devcontainer.json parse error: " .. tostring(err or "unknown"))
    return
  end
  h.ok("devcontainer.json parsed (" .. path .. ")")
  for _, key in ipairs({ "image", "dockerFile", "dockerComposeFile", "workspaceFolder" }) do
    if parsed[key] then h.info(key .. " = " .. tostring(parsed[key])) end
  end
end

function M.check()
  local h = health()
  h.start("devcontainer.nvim")
  check_cli()
  check_runtime()
  check_config()
end

return M
