-- Specs for `:checkhealth devcontainer`.
--
-- vim.fn.executable, vim.system, and vim.health.* are stubbed per-test so
-- we can drive each check independently and assert on the captured calls.

local function reset_modules()
  package.loaded["devcontainer"] = nil
  package.loaded["devcontainer.health"] = nil
  package.loaded["devcontainer.config"] = nil
  package.loaded["devcontainer.json"] = nil
end

--- Stub vim.system with a per-command result map keyed by argv[1].
---@param results table<string, { stdout?: string, stderr?: string, code?: number }>
local function stub_vim_system(results)
  local original = vim.system
  local captured = { calls = {} }
  vim.system = function(argv, _opts, _on_done)
    table.insert(captured.calls, argv)
    local r = results[argv[1]] or { code = 127 }
    return {
      pid = 1,
      wait = function()
        return {
          code = r.code or 0,
          signal = r.signal or 0,
          stdout = r.stdout or "",
          stderr = r.stderr or "",
        }
      end,
      kill = function() end,
    }
  end
  captured.restore = function() vim.system = original end
  return captured
end

--- Stub vim.fn.executable using a presence map.
---@param present table<string, boolean>
local function stub_executable(present)
  local original = vim.fn.executable
  vim.fn.executable = function(name) return present[name] and 1 or 0 end
  return function() vim.fn.executable = original end
end

--- Stub vim.health, capturing every call so tests can assert on results.
local function stub_health()
  local captured = { start = {}, ok = {}, warn = {}, error = {}, info = {} }
  local original = vim.health
  vim.health = {
    start = function(s) table.insert(captured.start, s) end,
    ok = function(s) table.insert(captured.ok, s) end,
    warn = function(s, _adv) table.insert(captured.warn, s) end,
    error = function(s, _adv) table.insert(captured.error, s) end,
    info = function(s) table.insert(captured.info, s) end,
  }
  captured.restore = function() vim.health = original end
  return captured
end

local function valid_workspace()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/.devcontainer", "p")
  local f = io.open(tmp .. "/.devcontainer/devcontainer.json", "w")
  f:write('{"image":"alpine:latest"}')
  f:close()
  require("devcontainer").config = { cli = "devcontainer", workspace_folder = tmp, auto_attach = true }
  package.loaded["devcontainer.config"] = nil
  return tmp
end

local function any_contains(list, needle)
  for _, s in ipairs(list) do
    if type(s) == "string" and s:find(needle, 1, true) then return true end
  end
  return false
end

describe("devcontainer.health.check", function()
  before_each(reset_modules)

  it("reports ok with version when CLI is present and --version succeeds", function()
    valid_workspace()
    local restore_exec = stub_executable({ devcontainer = true, docker = true })
    local sys = stub_vim_system({
      devcontainer = { stdout = "0.65.0\n", code = 0 },
      docker = { stdout = "Server:...\n", code = 0 },
    })
    local h = stub_health()
    require("devcontainer.health").check()
    h.restore(); sys.restore(); restore_exec()

    assert.is_true(any_contains(h.ok, "0.65.0"))
    assert.are.equal(0, #h.error)
  end)

  it("errors with install hint when devcontainer CLI is missing", function()
    local restore_exec = stub_executable({ docker = true })
    local sys = stub_vim_system({ docker = { code = 0 } })
    local h = stub_health()
    require("devcontainer.health").check()
    h.restore(); sys.restore(); restore_exec()

    assert.is_true(any_contains(h.error, "@devcontainers/cli"))
  end)

  it("warns when --version times out", function()
    local restore_exec = stub_executable({ devcontainer = true, docker = true })
    -- Simulate timeout: wait() returns nil-like result with signal != 0.
    local original = vim.system
    vim.system = function(argv, _opts, _on_done)
      if argv[1] == "devcontainer" then
        return { wait = function() return { code = 0, signal = 9, stdout = "", stderr = "" } end, kill = function() end }
      end
      return { wait = function() return { code = 0, stdout = "", stderr = "" } end, kill = function() end }
    end
    local h = stub_health()
    require("devcontainer.health").check()
    vim.system = original
    h.restore(); restore_exec()

    assert.is_true(any_contains(h.warn, "timed out") or any_contains(h.warn, "timeout"))
  end)

  it("reports ok runtime when `docker info` succeeds", function()
    local restore_exec = stub_executable({ devcontainer = true, docker = true })
    local sys = stub_vim_system({
      devcontainer = { stdout = "0.65.0", code = 0 },
      docker = { stdout = "Server:\n", code = 0 },
    })
    local h = stub_health()
    require("devcontainer.health").check()
    h.restore(); sys.restore(); restore_exec()

    assert.is_true(any_contains(h.ok, "docker"))
  end)

  it("falls back to podman when docker is unavailable", function()
    valid_workspace()
    local restore_exec = stub_executable({ devcontainer = true, podman = true })
    local sys = stub_vim_system({
      devcontainer = { stdout = "0.65.0", code = 0 },
      podman = { stdout = "host: ...\n", code = 0 },
    })
    local h = stub_health()
    require("devcontainer.health").check()
    h.restore(); sys.restore(); restore_exec()

    assert.is_true(any_contains(h.ok, "podman"))
    assert.are.equal(0, #h.error)
  end)

  it("warns when neither docker nor podman is present", function()
    local restore_exec = stub_executable({ devcontainer = true })
    local sys = stub_vim_system({ devcontainer = { stdout = "0.65.0", code = 0 } })
    local h = stub_health()
    require("devcontainer.health").check()
    h.restore(); sys.restore(); restore_exec()

    assert.is_true(any_contains(h.warn, "docker") and any_contains(h.warn, "podman"))
  end)

  it("errors when devcontainer.json is missing", function()
    local restore_exec = stub_executable({ devcontainer = true, docker = true })
    local sys = stub_vim_system({
      devcontainer = { stdout = "0.65.0", code = 0 },
      docker = { code = 0 },
    })
    -- Force find_config to return nil.
    require("devcontainer").config = { cli = "devcontainer", workspace_folder = "/tmp/no-such-dir-xyz", auto_attach = true }
    package.loaded["devcontainer.config"] = nil
    local h = stub_health()
    require("devcontainer.health").check()
    h.restore(); sys.restore(); restore_exec()

    assert.is_true(any_contains(h.error, "devcontainer.json"))
  end)

  it("errors with parse message when devcontainer.json is unparseable", function()
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir .. "/.devcontainer", "p")
    local f = io.open(tmpdir .. "/.devcontainer/devcontainer.json", "w")
    f:write("{ not valid json")
    f:close()

    local restore_exec = stub_executable({ devcontainer = true, docker = true })
    local sys = stub_vim_system({
      devcontainer = { stdout = "0.65.0", code = 0 },
      docker = { code = 0 },
    })
    require("devcontainer").config = { cli = "devcontainer", workspace_folder = tmpdir, auto_attach = true }
    package.loaded["devcontainer.config"] = nil
    local h = stub_health()
    require("devcontainer.health").check()
    h.restore(); sys.restore(); restore_exec()

    assert.is_true(any_contains(h.error, "parse"))
  end)
end)
