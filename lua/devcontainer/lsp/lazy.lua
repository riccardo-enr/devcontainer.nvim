--[==[
Lazy wrapper around the [[RPC proxy]] that lets the [[LSP cmd wrapper]] honor
the one-liner promise: if the [[devcontainer]] isn't running when nvim first
attaches an LSP client, `devcontainer up` is fired implicitly, outbound
JSON-RPC frames are queued, and the queue is drained into the real proxy
once `up` succeeds. See ADR-0007.

On `up` failure every queued request gets its callback invoked with an
error and `on_exit(1, 0)` is dispatched.
]==]

local M = {}

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
  local proxy = require("devcontainer.lsp.proxy")

  if container.state and container.state.running then
    return proxy.start(opts, dispatchers)
  end

  local queue = {}
  local real
  local closing = false
  local next_fake_id = -1

  local client = {
    request = nil,
    notify = nil,
    terminate = nil,
    is_closing = nil,
  }

  client.request = function(method, params, callback)
    if closing then return false end
    if real then return real.request(method, params, callback) end
    local id = next_fake_id
    next_fake_id = next_fake_id - 1
    table.insert(queue, {
      kind = "request", method = method, params = params, callback = callback, id = id,
    })
    return true, id
  end

  client.notify = function(method, params)
    if closing then return false end
    if real then return real.notify(method, params) end
    table.insert(queue, { kind = "notify", method = method, params = params })
    return true
  end

  client.terminate = function()
    closing = true
    if real and real.terminate then real.terminate() end
  end

  client.is_closing = function()
    if real then return real.is_closing() end
    return closing
  end

  container.up({
    on_exit = function(state, err)
      if err then
        closing = true
        for _, item in ipairs(queue) do
          if item.kind == "request" and item.callback then
            pcall(item.callback, err, nil)
          end
        end
        queue = {}
        if dispatchers.on_error then pcall(dispatchers.on_error, 0, err) end
        if dispatchers.on_exit then pcall(dispatchers.on_exit, 1, 0) end
        return
      end

      local real_opts = vim.tbl_extend("force", opts, {
        container_id = (state or {}).container_id,
        container_root = opts.container_root or (state or {}).remote_workspace_folder,
      })
      real = proxy.start(real_opts, dispatchers)
      for _, item in ipairs(queue) do
        if item.kind == "request" then
          real.request(item.method, item.params, item.callback)
        else
          real.notify(item.method, item.params)
        end
      end
      queue = {}
    end,
  })

  return client
end

return M
