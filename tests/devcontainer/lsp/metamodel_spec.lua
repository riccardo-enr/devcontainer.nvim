-- Specs for lua/devcontainer/lsp/metamodel.lua
--
-- The module loads the vendored LSP metaModel.json once and builds a
-- per-message map from { params, result, partialResult } to the JSON paths
-- where URI / DocumentUri leaves live. Only the message name -> URI-path
-- relation is exercised here; the lookup is consumed by uri_map.apply.

local function reset()
  package.loaded["devcontainer.lsp.metamodel"] = nil
end

local function has_path(paths, segs)
  for _, p in ipairs(paths) do
    if #p.segments == #segs then
      local match = true
      for i = 1, #segs do
        if p.segments[i] ~= segs[i] then match = false; break end
      end
      if match then return true end
    end
  end
  return false
end

describe("devcontainer.lsp.metamodel", function()
  before_each(reset)

  it("loads and caches the metaModel", function()
    local mm = require("devcontainer.lsp.metamodel")
    local a = mm.load()
    local b = mm.load()
    assert.is_table(a)
    assert.are.equal(a, b)
    assert.are.equal("3.17.0", a.metaData.version)
  end)

  it("textDocument/didOpen.params.textDocument.uri is in the lookup", function()
    local mm = require("devcontainer.lsp.metamodel")
    local lk = mm.lookup_for("textDocument/didOpen")
    assert.is_true(has_path(lk.params, { "textDocument", "uri" }))
  end)

  it("textDocument/definition.result contains uri, [*].uri, and [*].targetUri", function()
    local mm = require("devcontainer.lsp.metamodel")
    local lk = mm.lookup_for("textDocument/definition")
    assert.is_true(has_path(lk.result, { "uri" }))
    assert.is_true(has_path(lk.result, { "[*]", "uri" }))
    assert.is_true(has_path(lk.result, { "[*]", "targetUri" }))
  end)

  it("textDocument/references.result contains [*].uri", function()
    local mm = require("devcontainer.lsp.metamodel")
    local lk = mm.lookup_for("textDocument/references")
    assert.is_true(has_path(lk.result, { "[*]", "uri" }))
  end)

  it("textDocument/hover.result has no URI paths", function()
    local mm = require("devcontainer.lsp.metamodel")
    local lk = mm.lookup_for("textDocument/hover")
    assert.are.equal(0, #lk.result)
  end)

  it("returns empty tables for unknown messages", function()
    local mm = require("devcontainer.lsp.metamodel")
    local lk = mm.lookup_for("totally/made/up")
    assert.are.equal(0, #lk.params)
    assert.are.equal(0, #lk.result)
    assert.are.equal(0, #lk.partialResult)
  end)
end)
