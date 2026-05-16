-- Specs for lua/devcontainer/lsp/lazy.lua
--
-- The lazy wrapper queues outbound JSON-RPC while `devcontainer up` runs,
-- then drains the queue into the real proxy on success. On failure, every
-- pending request callback receives an error and on_exit is dispatched.

local function reset()
  package.loaded["devcontainer.lsp.lazy"] = nil
  package.loaded["devcontainer.lsp.proxy"] = nil
  package.loaded["devcontainer.lsp.metamodel"] = nil
  package.loaded["devcontainer.lsp.uri_map"] = nil
  package.loaded["devcontainer.container"] = nil
  package.loaded["devcontainer.config"] = nil
  package.loaded["devcontainer.buffer"] = nil
  package.loaded["devcontainer"] = nil
end

local function stub_vim_system()
  local captured = { argv = nil, opts = nil, written = {}, calls = 0 }
  local original = vim.system
  vim.system = function(argv, opts, _on_exit)
    captured.calls = captured.calls + 1
    captured.argv = argv
    captured.opts = opts
    return {
      write = function(_, data) table.insert(captured.written, data) end,
      kill = function() end,
    }
  end
  captured.restore = function() vim.system = original end
  return captured
end

--- Replace container.up with a deferred fake. The returned object lets the
--- test fire on_exit with success / failure at will.
local function stub_container_up()
  local container = require("devcontainer.container")
  container.state = {
    container_id = nil, remote_workspace_folder = nil, remote_user = nil,
    running = false, last_outcome = nil,
  }
  local pending
  container.up = function(opts) pending = opts end
  return {
    fire_success = function(state)
      container.state = state
      pending.on_exit(state, nil)
    end,
    fire_failure = function(err)
      pending.on_exit(container.state, err)
    end,
    called = function() return pending ~= nil end,
  }
end

local OPTS = {
  server_argv = { "clangd" },
  host_root = "/home/me/proj",
  container_root = "/workspaces/proj",
  workspace_folder = "/home/me/proj",
}

describe("devcontainer.lsp.lazy", function()
  before_each(reset)

  it("queues outbound notify until container.up succeeds, then drains", function()
    local up = stub_container_up()
    local sys = stub_vim_system()
    local lazy = require("devcontainer.lsp.lazy")
    local client = lazy.start(OPTS, {})

    local ok = client.notify("textDocument/didOpen", {
      textDocument = { uri = "file:///home/me/proj/x.c", languageId = "c", version = 1, text = "" },
    })
    assert.is_true(ok)
    assert.is_true(up.called(), "container.up must be invoked once on first call")
    assert.are.equal(0, sys.calls, "the real proxy must not spawn vim.system before up succeeds")

    up.fire_success({
      container_id = "abc123", remote_workspace_folder = "/workspaces/proj",
      remote_user = "vscode", running = true, last_outcome = "success",
    })

    assert.are.equal(1, sys.calls, "vim.system spawned after up success")
    assert.is_true(#sys.written >= 1, "queued frame replayed to the real proxy stdin")
    local last = sys.written[#sys.written]
    assert.is_truthy(last:find("textDocument/didOpen", 1, true))
    assert.is_truthy(last:find("file:///workspaces/proj/x.c", 1, true))
    sys.restore()
  end)

  it("errors each pending request callback and dispatches on_exit on up failure", function()
    local up = stub_container_up()
    local sys = stub_vim_system()
    local lazy = require("devcontainer.lsp.lazy")

    local exits, errs = {}, {}
    local req_err
    local client = lazy.start(OPTS, {
      on_error = function(_, e) table.insert(errs, e) end,
      on_exit  = function(code, sig) table.insert(exits, { code = code, sig = sig }) end,
    })
    client.request("textDocument/hover", {}, function(err, _) req_err = err end)

    up.fire_failure("devcontainer up failed: no docker daemon")

    assert.is_not_nil(req_err, "pending request callback must receive an error on failure")
    assert.are.equal(1, #exits)
    assert.are.equal(1, exits[1].code)
    assert.is_true(client.is_closing())
    assert.are.equal(0, sys.calls, "no real proxy on failure")
    sys.restore()
  end)

  it("forwards immediately when the container is already running", function()
    local container = require("devcontainer.container")
    container.state = {
      container_id = "live", remote_workspace_folder = "/workspaces/proj",
      remote_user = "vscode", running = true, last_outcome = "success",
    }
    local up_called = false
    container.up = function() up_called = true end
    local sys = stub_vim_system()
    local lazy = require("devcontainer.lsp.lazy")
    local client = lazy.start(OPTS, {})

    client.notify("textDocument/didOpen", {
      textDocument = { uri = "file:///home/me/proj/x.c", languageId = "c", version = 1, text = "" },
    })
    assert.is_false(up_called, "must not call up when already running")
    assert.are.equal(1, sys.calls)
    local last = sys.written[#sys.written]
    assert.is_truthy(last:find("file:///workspaces/proj/x.c", 1, true))
    sys.restore()
  end)
end)
