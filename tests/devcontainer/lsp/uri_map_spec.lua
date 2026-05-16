-- Specs for lua/devcontainer/lsp/uri_map.lua
--
-- Pure functions only. host->container, container->host, and the docker://
-- escape hatch for paths outside the container workspace. `apply` walks a
-- prescribed list of JSON paths rather than recursively scanning payloads.

local function reset()
  package.loaded["devcontainer.lsp.uri_map"] = nil
end

describe("devcontainer.lsp.uri_map", function()
  before_each(reset)

  describe("to_container", function()
    it("rewrites a host file:// URI rooted at host_root to container_root", function()
      local uri_map = require("devcontainer.lsp.uri_map")
      local out = uri_map.to_container(
        "file:///home/me/proj/src/main.c",
        "/home/me/proj",
        "/workspaces/proj"
      )
      assert.are.equal("file:///workspaces/proj/src/main.c", out)
    end)

    it("leaves non-file URIs alone", function()
      local uri_map = require("devcontainer.lsp.uri_map")
      assert.are.equal(
        "untitled:Untitled-1",
        uri_map.to_container("untitled:Untitled-1", "/home/me/proj", "/workspaces/proj")
      )
    end)

    it("leaves file URIs outside host_root alone", function()
      local uri_map = require("devcontainer.lsp.uri_map")
      assert.are.equal(
        "file:///tmp/other.c",
        uri_map.to_container("file:///tmp/other.c", "/home/me/proj", "/workspaces/proj")
      )
    end)
  end)

  describe("to_host", function()
    it("rewrites container workspace paths back to host", function()
      local uri_map = require("devcontainer.lsp.uri_map")
      local out = uri_map.to_host(
        "file:///workspaces/proj/src/main.c",
        "/home/me/proj",
        "/workspaces/proj",
        "abc123def"
      )
      assert.are.equal("file:///home/me/proj/src/main.c", out)
    end)

    it("rewrites foreign container paths to docker://<id>/<path>", function()
      local uri_map = require("devcontainer.lsp.uri_map")
      local out = uri_map.to_host(
        "file:///usr/include/stdio.h",
        "/home/me/proj",
        "/workspaces/proj",
        "abc123def"
      )
      assert.are.equal("docker://abc123def/usr/include/stdio.h", out)
    end)

    it("leaves non-file URIs alone", function()
      local uri_map = require("devcontainer.lsp.uri_map")
      assert.are.equal(
        "untitled:Untitled-1",
        uri_map.to_host("untitled:Untitled-1", "/home/me/proj", "/workspaces/proj", "abc")
      )
    end)
  end)

  describe("round-trip", function()
    it("is identity for workspace URIs", function()
      local uri_map = require("devcontainer.lsp.uri_map")
      local host = "file:///home/me/proj/src/x.c"
      local round = uri_map.to_host(
        uri_map.to_container(host, "/home/me/proj", "/workspaces/proj"),
        "/home/me/proj", "/workspaces/proj", "abc"
      )
      assert.are.equal(host, round)
    end)
  end)

  describe("apply", function()
    it("rewrites only fields listed in paths and ignores siblings", function()
      local uri_map = require("devcontainer.lsp.uri_map")
      local payload = {
        textDocument = {
          uri = "file:///host/x.c",
          languageId = "c",
          text = "file:///host/x.c -- not a uri field, just text",
        },
      }
      local paths = { { segments = { "textDocument", "uri" } } }
      uri_map.apply(payload, paths, function(u) return "REWRITTEN:" .. u end)
      assert.are.equal("REWRITTEN:file:///host/x.c", payload.textDocument.uri)
      assert.are.equal("c", payload.textDocument.languageId)
      assert.are.equal("file:///host/x.c -- not a uri field, just text", payload.textDocument.text)
    end)

    it("walks arrays via [*] segment", function()
      local uri_map = require("devcontainer.lsp.uri_map")
      local payload = {
        { uri = "file:///host/a.c", range = {} },
        { uri = "file:///host/b.c", range = {} },
      }
      local paths = { { segments = { "[*]", "uri" } } }
      uri_map.apply(payload, paths, function(u) return u .. "!" end)
      assert.are.equal("file:///host/a.c!", payload[1].uri)
      assert.are.equal("file:///host/b.c!", payload[2].uri)
    end)

    it("tolerates missing paths without erroring", function()
      local uri_map = require("devcontainer.lsp.uri_map")
      local payload = { textDocument = { uri = "file:///x" } }
      local paths = {
        { segments = { "textDocument", "uri" } },
        { segments = { "missing", "field" } },
      }
      uri_map.apply(payload, paths, function(u) return u .. "?" end)
      assert.are.equal("file:///x?", payload.textDocument.uri)
    end)
  end)
end)
