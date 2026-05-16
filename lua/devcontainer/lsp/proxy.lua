--[==[
[[RPC proxy]] for an in-container LSP server.

Implements the cmd-as-function contract Neovim's LSP client expects:
`vim.lsp.start{ cmd = function(dispatchers) return proxy.start(opts, dispatchers) end, ... }`.

On each direction the proxy looks up the URI-bearing JSON paths for the
message (`uri_map.apply` + the [[metaModel lookup table]] from
`devcontainer.lsp.metamodel`) and rewrites only those leaves:

  * outbound: host `file://` paths -> [[workspaceFolder]] paths in the container.
  * inbound: workspace paths -> host paths; foreign container paths -> [[docker:// scheme]].

The child process is `devcontainer exec --workspace-folder <ws> <server...>`
spawned via `vim.system` with stdin enabled.
]==]

local M = {}

local uri_map = require("devcontainer.lsp.uri_map")
local metamodel = require("devcontainer.lsp.metamodel")

--- Build a noop client that immediately reports closed.
local function closed_client()
  return {
    request = function() return false end,
    notify = function() return false end,
    terminate = function() end,
    is_closing = function() return true end,
  }
end

function M.start(opts, dispatchers)
  dispatchers = dispatchers or {}

  local container = require("devcontainer.container")
  if not container.state or not container.state.running then
    vim.schedule(function()
      if dispatchers.on_error then
        dispatchers.on_error(0, "devcontainer.nvim: container is not running; call :DevcontainerUp")
      end
      if dispatchers.on_exit then dispatchers.on_exit(1, 0) end
    end)
    return closed_client()
  end

  local host_root = opts.host_root
  local container_root = opts.container_root or container.state.remote_workspace_folder
  local container_id = opts.container_id or container.state.container_id
  local workspace_folder = opts.workspace_folder or host_root

  local function out_rewrite(uri)
    return uri_map.to_container(uri, host_root, container_root)
  end
  local function in_rewrite(uri)
    return uri_map.to_host(uri, host_root, container_root, container_id)
  end

  local function rewrite_payload(method, payload, kind, rewrite)
    if type(payload) ~= "table" then return end
    local lk = metamodel.lookup_for(method)
    uri_map.apply(payload, lk[kind] or {}, rewrite)
  end

  local pending = {}      -- request id -> { method }
  local next_id = 1
  local buf = ""
  local closing = false
  local sys

  local cli = (require("devcontainer").config or {}).cli or "devcontainer"
  local argv = { cli, "exec", "--workspace-folder", workspace_folder }
  for _, a in ipairs(opts.server_argv or {}) do argv[#argv + 1] = a end

  --- Decode and dispatch any complete frames sitting in `buf`.
  local function dispatch_frames()
    while true do
      local hdr_end = buf:find("\r\n\r\n", 1, true)
      if not hdr_end then return end
      local len = tonumber(buf:sub(1, hdr_end - 1):match("Content%-Length:%s*(%d+)"))
      if not len then
        buf = buf:sub(hdr_end + 4)
        return
      end
      if #buf < hdr_end + 3 + len then return end
      local body = buf:sub(hdr_end + 4, hdr_end + 3 + len)
      buf = buf:sub(hdr_end + 4 + len)
      local ok, msg = pcall(vim.json.decode, body)
      if ok and type(msg) == "table" then
        if msg.id ~= nil and (msg.result ~= nil or msg.error ~= nil) then
          local p = pending[msg.id]
          pending[msg.id] = nil
          if p and msg.result ~= nil then
            rewrite_payload(p.method, msg.result, "result", in_rewrite)
          end
          if p and p.callback then
            pcall(p.callback, msg.error, msg.result)
          end
        elseif msg.method then
          rewrite_payload(msg.method, msg.params, "params", in_rewrite)
          if msg.id ~= nil then
            if dispatchers.server_request then
              local result, err = dispatchers.server_request(msg.method, msg.params)
              local reply = { jsonrpc = "2.0", id = msg.id }
              if err then reply.error = err else reply.result = result end
              M._send(sys, reply)
            end
          else
            if dispatchers.notification then
              pcall(dispatchers.notification, msg.method, msg.params)
            end
          end
        end
      end
    end
  end

  sys = vim.system(argv, {
    text = true,
    stdin = true,
    stdout = function(_, chunk)
      if not chunk or chunk == "" then return end
      buf = buf .. chunk
      dispatch_frames()
    end,
    stderr = function(_, _) end,
  }, function(res)
    closing = true
    if dispatchers.on_exit then
      vim.schedule(function() dispatchers.on_exit((res or {}).code or 0, (res or {}).signal or 0) end)
    end
  end)

  local function send(msg)
    local body = vim.json.encode(msg)
    local frame = "Content-Length: " .. #body .. "\r\n\r\n" .. body
    if sys and sys.write then sys:write(frame) end
  end
  M._send = function(_, msg) send(msg) end

  return {
    request = function(method, params, callback)
      if closing then return false end
      rewrite_payload(method, params, "params", out_rewrite)
      local id = next_id
      next_id = id + 1
      pending[id] = { method = method, callback = callback }
      send({ jsonrpc = "2.0", id = id, method = method, params = params })
      return true, id
    end,
    notify = function(method, params)
      if closing then return false end
      rewrite_payload(method, params, "params", out_rewrite)
      send({ jsonrpc = "2.0", method = method, params = params })
      return true
    end,
    terminate = function()
      closing = true
      if sys and sys.kill then pcall(sys.kill, sys, 15) end
    end,
    is_closing = function() return closing end,
  }
end

return M
