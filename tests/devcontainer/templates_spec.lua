-- Specs for the :DevcontainerTemplate picker module.
--
-- Network is fully stubbed via dependency injection of an HTTP client onto
-- `M._http`. Cache root is overridden to a per-test tmpdir so the on-disk
-- TTL semantics can be exercised deterministically.

local function reset_modules()
  package.loaded["devcontainer"] = nil
  package.loaded["devcontainer.templates"] = nil
  package.loaded["devcontainer.http"] = nil
  package.loaded["devcontainer.config"] = nil
end

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local function write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--- Build an HTTP stub. `routes` maps URL substrings to either a string body
--- (success) or { err = "..." } (failure). Records every call.
local function make_http(routes)
  local calls = {}
  local stub = {}
  stub.get = function(url, cb)
    table.insert(calls, url)
    local match
    for pat, resp in pairs(routes) do
      if url:find(pat, 1, true) then
        match = resp
        break
      end
    end
    vim.schedule(function()
      if match == nil then
        cb(nil, "no route for " .. url)
      elseif type(match) == "table" and match.err then
        cb(nil, match.err)
      else
        cb(match, nil)
      end
    end)
  end
  stub.calls = calls
  return stub
end

--- Minimal valid GitHub tree response with two templates: python, go.
local function fake_tree_json()
  return vim.json.encode({
    sha = "deadbeef",
    truncated = false,
    tree = {
      { path = "src/python/devcontainer-template.json", type = "blob" },
      { path = "src/python/.devcontainer/devcontainer.json", type = "blob" },
      { path = "src/python/.devcontainer/post-create.sh", type = "blob" },
      { path = "src/go/devcontainer-template.json", type = "blob" },
      { path = "src/go/.devcontainer/devcontainer.json", type = "blob" },
      { path = "README.md", type = "blob" }, -- non-template entry, must be filtered
    },
  })
end

local function fake_metadata(id, name, description)
  return vim.json.encode({
    id = id,
    name = name,
    description = description,
    options = {},
    platforms = { "linux" },
    publisher = "devcontainers",
  })
end

local function wait_for(predicate, timeout_ms)
  return vim.wait(timeout_ms or 1000, predicate, 10)
end

describe("devcontainer.templates.list", function()
  before_each(reset_modules)

  it("reads a fresh on-disk cache without hitting HTTP", function()
    local cache_root = tmpdir()
    local catalog = {
      fetched_at = os.time() - 60, -- 1 minute old, well within TTL
      entries = {
        { id = "python", name = "Python 3", description = "Py.",
          files = { "devcontainer.json" } },
      },
    }
    write_file(cache_root .. "/catalog.json", vim.json.encode(catalog))

    local templates = require("devcontainer.templates")
    templates._cache_root = cache_root
    local http = make_http({})
    templates._http = http

    local result, err
    templates.list({}, function(entries, e) result, err = entries, e end)
    wait_for(function() return result ~= nil or err ~= nil end)

    assert.is_nil(err)
    assert.are.equal(1, #result)
    assert.are.equal("python", result[1].id)
    assert.are.equal(0, #http.calls)
  end)

  it("refreshes when the cache is older than 24h", function()
    local cache_root = tmpdir()
    local catalog = {
      fetched_at = os.time() - (25 * 3600), -- stale
      entries = { { id = "old", name = "Old", description = "", files = {} } },
    }
    write_file(cache_root .. "/catalog.json", vim.json.encode(catalog))

    local templates = require("devcontainer.templates")
    templates._cache_root = cache_root
    templates._http = make_http({
      ["git/trees/main"] = fake_tree_json(),
      ["src/python/devcontainer-template.json"] = fake_metadata("python", "Python 3", "Py."),
      ["src/python/.devcontainer/devcontainer.json"] = "{ \"image\": \"python:3\" }",
      ["src/python/.devcontainer/post-create.sh"] = "#!/bin/sh\n",
      ["src/go/devcontainer-template.json"] = fake_metadata("go", "Go", "Go."),
      ["src/go/.devcontainer/devcontainer.json"] = "{ \"image\": \"golang:1\" }",
    })

    local result, err
    templates.list({}, function(entries, e) result, err = entries, e end)
    wait_for(function() return result ~= nil or err ~= nil end)

    assert.is_nil(err)
    local ids = {}
    for _, e in ipairs(result) do table.insert(ids, e.id) end
    table.sort(ids)
    assert.are.same({ "go", "python" }, ids)
  end)

  it("returns cached entries and notifies when fetch fails but cache exists",
    function()
      local cache_root = tmpdir()
      local catalog = {
        fetched_at = os.time() - (25 * 3600),
        entries = { { id = "python", name = "Python 3", description = "Py.",
          files = { "devcontainer.json" } } },
      }
      write_file(cache_root .. "/catalog.json", vim.json.encode(catalog))

      local templates = require("devcontainer.templates")
      templates._cache_root = cache_root
      templates._http = make_http({ ["git/trees/main"] = { err = "network down" } })

      local notified = {}
      local original_notify = vim.notify
      vim.notify = function(msg, lvl) table.insert(notified, { msg = msg, lvl = lvl }) end

      local result, err
      templates.list({}, function(entries, e) result, err = entries, e end)
      wait_for(function() return result ~= nil or err ~= nil end)
      vim.notify = original_notify

      assert.is_nil(err)
      assert.are.equal("python", result[1].id)
      local saw_stale = false
      for _, n in ipairs(notified) do
        if n.msg:lower():find("stale", 1, true) then saw_stale = true end
      end
      assert.is_true(saw_stale)
    end)

  it("errors when there is no cache and fetch fails", function()
    local cache_root = tmpdir()
    local templates = require("devcontainer.templates")
    templates._cache_root = cache_root
    templates._http = make_http({ ["git/trees/main"] = { err = "network down" } })

    local result, err
    templates.list({}, function(entries, e) result, err = entries, e end)
    wait_for(function() return result ~= nil or err ~= nil end)

    assert.is_nil(result)
    assert.is_not_nil(err)
    assert.is_truthy(err:lower():find("network down", 1, true)
      or err:lower():find("fetch", 1, true))
  end)
end)

describe("devcontainer.templates.apply", function()
  before_each(reset_modules)

  local function seed_cache(cache_root)
    local catalog = {
      fetched_at = os.time(),
      entries = {
        { id = "python", name = "Python 3", description = "Py.",
          files = { "devcontainer.json", "post-create.sh" } },
      },
    }
    write_file(cache_root .. "/catalog.json", vim.json.encode(catalog))
    write_file(cache_root .. "/python/devcontainer.json", "{ \"image\": \"python:3\" }")
    write_file(cache_root .. "/python/post-create.sh", "#!/bin/sh\necho hi\n")
  end

  it("refuses to overwrite an existing .devcontainer/ without force", function()
    local cache_root = tmpdir()
    seed_cache(cache_root)
    local workspace = tmpdir()
    vim.fn.mkdir(workspace .. "/.devcontainer", "p")
    write_file(workspace .. "/.devcontainer/devcontainer.json", "{ \"image\": \"existing\" }")

    local templates = require("devcontainer.templates")
    templates._cache_root = cache_root
    templates._http = make_http({})

    local written, err
    templates.apply("python", workspace, {}, function(w, e) written, err = w, e end)
    wait_for(function() return written ~= nil or err ~= nil end)

    assert.is_nil(written)
    assert.is_not_nil(err)
    assert.is_truthy(err:lower():find("exists", 1, true))
    -- Ensure original file untouched.
    assert.are.equal("{ \"image\": \"existing\" }",
      read_file(workspace .. "/.devcontainer/devcontainer.json"))
  end)

  it("writes every cached file when force is true", function()
    local cache_root = tmpdir()
    seed_cache(cache_root)
    local workspace = tmpdir()
    vim.fn.mkdir(workspace .. "/.devcontainer", "p")
    write_file(workspace .. "/.devcontainer/devcontainer.json", "{ \"image\": \"existing\" }")

    local templates = require("devcontainer.templates")
    templates._cache_root = cache_root
    templates._http = make_http({})

    local written, err
    templates.apply("python", workspace, { force = true }, function(w, e) written, err = w, e end)
    wait_for(function() return written ~= nil or err ~= nil end)

    assert.is_nil(err)
    assert.are.equal(2, #written)
    assert.are.equal("{ \"image\": \"python:3\" }",
      read_file(workspace .. "/.devcontainer/devcontainer.json"))
    assert.are.equal("#!/bin/sh\necho hi\n",
      read_file(workspace .. "/.devcontainer/post-create.sh"))
  end)

  it("scaffolds onto a workspace with no existing .devcontainer/", function()
    local cache_root = tmpdir()
    seed_cache(cache_root)
    local workspace = tmpdir()

    local templates = require("devcontainer.templates")
    templates._cache_root = cache_root
    templates._http = make_http({})

    local written, err
    templates.apply("python", workspace, {}, function(w, e) written, err = w, e end)
    wait_for(function() return written ~= nil or err ~= nil end)

    assert.is_nil(err)
    assert.are.equal(2, #written)
    assert.is_not_nil(read_file(workspace .. "/.devcontainer/devcontainer.json"))
    assert.is_not_nil(read_file(workspace .. "/.devcontainer/post-create.sh"))
  end)

  it("errors when the template id is unknown", function()
    local cache_root = tmpdir()
    seed_cache(cache_root)
    local workspace = tmpdir()

    local templates = require("devcontainer.templates")
    templates._cache_root = cache_root
    templates._http = make_http({})

    local written, err
    templates.apply("nonsense", workspace, {}, function(w, e) written, err = w, e end)
    wait_for(function() return written ~= nil or err ~= nil end)

    assert.is_nil(written)
    assert.is_not_nil(err)
    assert.is_truthy(err:lower():find("unknown", 1, true)
      or err:lower():find("not found", 1, true))
  end)
end)

describe(":DevcontainerTemplate command", function()
  before_each(reset_modules)

  it("is registered after setup() and invokes vim.ui.select", function()
    local cache_root = tmpdir()
    write_file(cache_root .. "/catalog.json", vim.json.encode({
      fetched_at = os.time(),
      entries = {
        { id = "python", name = "Python 3", description = "Py.",
          files = { "devcontainer.json" } },
      },
    }))
    write_file(cache_root .. "/python/devcontainer.json", "{}")

    require("devcontainer").setup({})
    local templates = require("devcontainer.templates")
    templates._cache_root = cache_root
    templates._http = make_http({})

    -- Stub vim.ui.select to capture invocation and immediately cancel.
    local select_calls = {}
    local original_select = vim.ui.select
    vim.ui.select = function(items, opts, on_choice)
      table.insert(select_calls, { items = items, opts = opts })
      on_choice(nil) -- user cancelled
    end

    local ok = pcall(vim.cmd, "DevcontainerTemplate")
    -- Allow the async list -> ui.select scheduling to flush.
    wait_for(function() return #select_calls > 0 end)
    vim.ui.select = original_select

    assert.is_true(ok)
    assert.are.equal(1, #select_calls)
    assert.are.equal("python", select_calls[1].items[1].id)
  end)
end)
