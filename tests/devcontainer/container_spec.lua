-- Specs for the async devcontainer CLI wrapper.
--
-- vim.system is stubbed per-test so we can drive stdout, stderr, and the
-- exit code synchronously. The wrapper must call `on_exit` exactly once on
-- the main loop with a parsed `container state` table.

local function reset_modules()
  package.loaded["devcontainer"] = nil
  package.loaded["devcontainer.container"] = nil
  package.loaded["devcontainer.commands"] = nil
  package.loaded["devcontainer.config"] = nil
  package.loaded["devcontainer.buffer"] = nil
end

--- Build a stub for vim.system that captures the argv and delivers a
--- prepared result to the completion callback synchronously.
---@param result table { stdout = string, stderr = string, code = number, signal? = number }
---@return table { argv = nil, opts = nil }
local function stub_vim_system(result)
  local captured = { argv = nil, opts = nil }
  local original = vim.system
  vim.system = function(argv, opts, on_done)
    captured.argv = argv
    captured.opts = opts
    -- Mimic the real vim.system contract: on_done runs on the libuv thread.
    -- Our wrapper must schedule before notifying / writing buffers.
    vim.schedule(function()
      on_done({
        code = result.code or 0,
        signal = result.signal or 0,
        stdout = result.stdout or "",
        stderr = result.stderr or "",
      })
    end)
    return { pid = 1, wait = function() return result end, kill = function() end }
  end
  captured.restore = function() vim.system = original end
  return captured
end

local function wait_for(predicate, timeout_ms)
  vim.wait(timeout_ms or 1000, predicate, 10)
end

describe("devcontainer.container.up", function()
  before_each(reset_modules)

  it("parses the JSON outcome and caches container state", function()
    local stub = stub_vim_system({
      stdout = '{"outcome":"success","containerId":"abc123def","remoteWorkspaceFolder":"/workspaces/p","remoteUser":"vscode"}\n',
      code = 0,
    })
    local container = require("devcontainer.container")
    local got
    container.up({ on_exit = function(state, err) got = { state = state, err = err } end })
    wait_for(function() return got ~= nil end)
    stub.restore()

    assert.is_nil(got.err)
    assert.are.equal("abc123def", got.state.container_id)
    assert.are.equal("/workspaces/p", got.state.remote_workspace_folder)
    assert.are.equal("vscode", got.state.remote_user)
    assert.is_true(got.state.running)
    assert.are.equal("abc123def", container.state.container_id)
  end)

  it("passes --workspace-folder and the configured cli to vim.system", function()
    local stub = stub_vim_system({ stdout = '{"outcome":"success","containerId":"x"}', code = 0 })
    require("devcontainer").config = { cli = "devcontainer", workspace_folder = "/tmp/proj", auto_attach = true }
    local container = require("devcontainer.container")
    local done = false
    container.up({ on_exit = function() done = true end })
    wait_for(function() return done end)
    stub.restore()

    assert.are.equal("devcontainer", stub.argv[1])
    assert.are.equal("up", stub.argv[2])
    local joined = table.concat(stub.argv, " ")
    assert.is_truthy(joined:find("--workspace-folder", 1, true))
    assert.is_truthy(joined:find("/tmp/proj", 1, true))
  end)

  it("adds rebuild flags when rebuild = true", function()
    local stub = stub_vim_system({ stdout = '{"outcome":"success","containerId":"x"}', code = 0 })
    local container = require("devcontainer.container")
    local done = false
    container.up({ rebuild = true, on_exit = function() done = true end })
    wait_for(function() return done end)
    stub.restore()

    local joined = table.concat(stub.argv, " ")
    assert.is_truthy(joined:find("--remove-existing-container", 1, true))
    assert.is_truthy(joined:find("--build-no-cache", 1, true))
  end)

  it("invokes on_exit exactly once on non-zero exit and keeps running = false", function()
    local stub = stub_vim_system({ stdout = "", stderr = "boom: something broke\n", code = 1 })
    local container = require("devcontainer.container")
    local calls = 0
    local got_err
    container.up({ on_exit = function(_, err) calls = calls + 1; got_err = err end })
    wait_for(function() return calls > 0 end)
    -- Give the loop a chance to over-fire.
    vim.wait(50)
    stub.restore()

    assert.are.equal(1, calls)
    assert.is_not_nil(got_err)
    assert.is_false(container.state.running)
  end)

  it("maps ENOENT-style stderr to an install-cli hint via vim.notify", function()
    local notes = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
    local stub = stub_vim_system({
      stdout = "",
      stderr = "/bin/sh: devcontainer: command not found\n",
      code = 127,
    })
    local container = require("devcontainer.container")
    local done = false
    container.up({ on_exit = function() done = true end })
    wait_for(function() return done end)
    stub.restore()
    vim.notify = original_notify

    local saw_hint = false
    for _, n in ipairs(notes) do
      if type(n.msg) == "string" and n.msg:find("@devcontainers/cli", 1, true) then saw_hint = true end
    end
    assert.is_true(saw_hint)
  end)
end)

describe("devcontainer.container.status", function()
  before_each(reset_modules)

  it("short-circuits when container_id is already cached", function()
    local container = require("devcontainer.container")
    container.state = {
      container_id = "cached123",
      remote_workspace_folder = "/workspaces/p",
      remote_user = "vscode",
      running = true,
      last_outcome = "success",
    }
    local invoked = false
    local original = vim.system
    vim.system = function() invoked = true; return {} end

    local got
    container.status({ on_exit = function(state) got = state end })
    wait_for(function() return got ~= nil end)
    vim.system = original

    assert.is_false(invoked)
    assert.are.equal("cached123", got.container_id)
    assert.is_true(got.running)
  end)

  it("falls back to up() when nothing is cached", function()
    local stub = stub_vim_system({
      stdout = '{"outcome":"success","containerId":"fresh"}',
      code = 0,
    })
    local container = require("devcontainer.container")
    local got
    container.status({ on_exit = function(state) got = state end })
    wait_for(function() return got ~= nil end)
    stub.restore()

    assert.are.equal("fresh", got.container_id)
  end)
end)
