--[[
JSONC parser and variable substitution for `devcontainer.json`.

Parses files conforming to the containers.dev spec, including `//` and
`/* */` comments, trailing commas, and the `${localWorkspaceFolder}`,
`${containerWorkspaceFolder}`, and `${localEnv:VAR}` substitutions.

See ADR-0001 for the rationale behind the preprocessor-plus-vim.json
strategy.
]]

local M = {}

--- Strip JSONC syntax (comments + trailing commas) while respecting
--- string boundaries and escape sequences.
---@param src string
---@return string
local function strip_jsonc(src)
  local out = {}
  local i, n = 1, #src
  local in_string = false
  while i <= n do
    local c = src:sub(i, i)
    if in_string then
      if c == "\\" and i < n then
        out[#out + 1] = c
        out[#out + 1] = src:sub(i + 1, i + 1)
        i = i + 2
      else
        out[#out + 1] = c
        if c == '"' then in_string = false end
        i = i + 1
      end
    else
      if c == '"' then
        in_string = true
        out[#out + 1] = c
        i = i + 1
      elseif c == "/" and i < n and src:sub(i + 1, i + 1) == "/" then
        local nl = src:find("\n", i + 2, true)
        i = nl and nl or (n + 1)
      elseif c == "/" and i < n and src:sub(i + 1, i + 1) == "*" then
        local close = src:find("*/", i + 2, true)
        i = close and (close + 2) or (n + 1)
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
  end
  -- Remove trailing commas before `}` or `]`. Scan the assembled output,
  -- ignoring commas that sit inside strings.
  local joined = table.concat(out)
  local cleaned = {}
  local j, m = 1, #joined
  in_string = false
  while j <= m do
    local c = joined:sub(j, j)
    if in_string then
      if c == "\\" and j < m then
        cleaned[#cleaned + 1] = c
        cleaned[#cleaned + 1] = joined:sub(j + 1, j + 1)
        j = j + 2
      else
        cleaned[#cleaned + 1] = c
        if c == '"' then in_string = false end
        j = j + 1
      end
    else
      if c == '"' then
        in_string = true
        cleaned[#cleaned + 1] = c
        j = j + 1
      elseif c == "," then
        local k = j + 1
        while k <= m and joined:sub(k, k):match("%s") do k = k + 1 end
        local nxt = joined:sub(k, k)
        if nxt == "}" or nxt == "]" then
          j = j + 1 -- drop the comma
        else
          cleaned[#cleaned + 1] = c
          j = j + 1
        end
      else
        cleaned[#cleaned + 1] = c
        j = j + 1
      end
    end
  end
  return table.concat(cleaned)
end

--- Decode JSONC text into a Lua table.
---@param text string
---@return table?, string?
function M.decode(text)
  local stripped = strip_jsonc(text)
  local ok, result = pcall(vim.json.decode, stripped)
  if not ok then return nil, tostring(result) end
  return result, nil
end

--- Apply variable substitution to a string, walking tables recursively.
--- Replaces `${localWorkspaceFolder}`, `${containerWorkspaceFolder}`, and
--- `${localEnv:NAME}`. Missing env vars resolve to the empty string per
--- the containers.dev spec.
---@param value any
---@param env { localWorkspaceFolder?: string, containerWorkspaceFolder?: string }
---@return any
function M.substitute(value, env)
  if type(value) == "string" then
    local s = value
    s = s:gsub("%${localWorkspaceFolder}", env.localWorkspaceFolder or "")
    s = s:gsub("%${containerWorkspaceFolder}", env.containerWorkspaceFolder or "")
    s = s:gsub("%${localEnv:([%w_]+)}", function(name)
      return vim.env[name] or ""
    end)
    return s
  elseif type(value) == "table" then
    local out = {}
    for k, v in pairs(value) do
      out[k] = M.substitute(v, env)
    end
    return out
  end
  return value
end

--- Read and parse a `devcontainer.json` at `path`, resolving substitutions
--- and defaulting `workspaceFolder` to `/workspaces/<basename(local)>`.
---@param path string
---@param opts? { localWorkspaceFolder?: string }
---@return table?, string?
function M.parse(path, opts)
  opts = opts or {}
  local fd, ferr = io.open(path, "r")
  if not fd then return nil, ferr or ("cannot open " .. path) end
  local text = fd:read("*a")
  fd:close()

  local raw, derr = M.decode(text)
  if not raw then return nil, derr end

  local local_ws = opts.localWorkspaceFolder
  if not local_ws then
    local ok, mod = pcall(require, "devcontainer.config")
    if ok and mod and mod.workspace_folder then
      local_ws = mod.workspace_folder()
    else
      local_ws = vim.fn.getcwd()
    end
  end

  -- First pass: resolve only host-side variables so we can compute the
  -- final workspaceFolder before the second pass.
  local first_env = { localWorkspaceFolder = local_ws, containerWorkspaceFolder = "" }
  local raw_ws = raw.workspaceFolder
  local resolved_ws
  if type(raw_ws) == "string" then
    resolved_ws = M.substitute(raw_ws, first_env)
  else
    local basename = vim.fn.fnamemodify(local_ws, ":t")
    resolved_ws = "/workspaces/" .. basename
  end

  local env = { localWorkspaceFolder = local_ws, containerWorkspaceFolder = resolved_ws }
  local cfg = M.substitute(raw, env)
  cfg.workspaceFolder = resolved_ws
  return cfg, nil
end

--- Locate and parse the workspace's `devcontainer.json` in one call.
---@param opts? { localWorkspaceFolder?: string }
---@return table?, string?
function M.load(opts)
  opts = opts or {}
  local cfg_mod = require("devcontainer.config")
  local path = cfg_mod.find_config()
  if not path then return nil, "no devcontainer.json found" end
  return M.parse(path, opts)
end

return M
