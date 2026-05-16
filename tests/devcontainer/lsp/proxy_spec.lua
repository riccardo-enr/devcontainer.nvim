-- Specs for lua/devcontainer/lsp/proxy.lua
--
-- The proxy implements the cmd-as-function contract Neovim's LSP client
-- expects. We stub vim.system to capture argv + stdin writes and to inject
-- synthetic stdout frames, then assert URI rewriting in both directions.

local function reset()
  package.loaded["devcontainer.lsp.proxy"] = nil
  package.loaded["devcontainer.lsp.metamodel"] = nil
  package.loaded["devcontainer.lsp.uri_map"] = nil
  package.loaded["devcontainer"] = nil
  package.loaded["devcontainer.container"] = nil
  package.loaded["devcontainer.config"] = nil
end

local function stub_vim_system()
  local captured = { argv = nil, opts = nil, on_exit_cb = nil, written = {}, killed = false }
  local original = vim.system
  vim.system = function(argv, opts, on_exit_cb)
    captured.argv = argv
    captured.opts = opts
    captured.on_exit_cb = on_exit_cb
    local handle = {
      write = function(_, data) table.insert(captured.written, data) end,
      kill = function() captured.killed = true end,
    }
    return handle
  end
  captured.restore = function() vim.system = original end
  return captured
end

local function frame(body)
  return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

local function decode_last_written(captured)
  local last = captured.written[#captured.written]
  local _, _, body = last:find("\r\n\r\n(.*)$")
  return vim.json.decode(body)
end

local function set_container_state(id, remote_ws)
  require("devcontainer.container").state = {
    container_id = id,
    remote_workspace_folder = remote_ws,
    remote_user = "vscode",
    running = true,
    last_outcome = "success",
  }
end

local OPTS = {
  server_argv = { "clangd" },
  host_root = "/home/me/proj",
  container_root = "/workspaces/proj",
  container_id = "abc123",
  workspace_folder = "/home/me/proj",
}

describe("devcontainer.lsp.proxy", function()
  before_each(function()
    reset()
    set_container_state("abc123", "/workspaces/proj")
  end)

  it("rewrites outbound didOpen URI host -> container", function()
    local stub = stub_vim_system()
    local proxy = require("devcontainer.lsp.proxy")
    local client = proxy.start(OPTS, {})
    client.notify("textDocument/didOpen", {
      textDocument = { uri = "file:///home/me/proj/src/main.c", languageId = "c", version = 1, text = "" },
    })
    local msg = decode_last_written(stub)
    assert.are.equal("textDocument/didOpen", msg.method)
    assert.are.equal("file:///workspaces/proj/src/main.c", msg.params.textDocument.uri)
    stub.restore()
  end)

  it("rewrites outbound request params and inbound result host<->container", function()
    local stub = stub_vim_system()
    local proxy = require("devcontainer.lsp.proxy")
    local got
    local client = proxy.start(OPTS, {})
    client.request("textDocument/references", {
      textDocument = { uri = "file:///home/me/proj/src/main.c" },
      position = { line = 1, character = 2 },
      context = { includeDeclaration = true },
    }, function(err, result) got = { err = err, result = result } end)
    local outbound = decode_last_written(stub)
    assert.are.equal("file:///workspaces/proj/src/main.c", outbound.params.textDocument.uri)
    -- Simulate server response containing one workspace location and one system header
    local response = {
      jsonrpc = "2.0",
      id = outbound.id,
      result = {
        { uri = "file:///workspaces/proj/src/main.c", range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } } },
        { uri = "file:///usr/include/stdio.h",       range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } } },
      },
    }
    stub.opts.stdout(nil, frame(vim.json.encode(response)))
    vim.wait(200, function() return got ~= nil end, 5)
    assert.is_not_nil(got, "response callback was not invoked")
    assert.are.equal("file:///home/me/proj/src/main.c", got.result[1].uri)
    assert.are.equal("docker://abc123/usr/include/stdio.h", got.result[2].uri)
    stub.restore()
  end)

  it("rewrites inbound server notifications (publishDiagnostics)", function()
    local stub = stub_vim_system()
    local proxy = require("devcontainer.lsp.proxy")
    local seen
    local client = proxy.start(OPTS, {
      notification = function(method, params) seen = { method = method, params = params } end,
    })
    local notif = {
      jsonrpc = "2.0",
      method = "textDocument/publishDiagnostics",
      params = {
        uri = "file:///workspaces/proj/src/main.c",
        diagnostics = {},
      },
    }
    stub.opts.stdout(nil, frame(vim.json.encode(notif)))
    vim.wait(200, function() return seen ~= nil end, 5)
    assert.is_not_nil(seen)
    assert.are.equal("file:///home/me/proj/src/main.c", seen.params.uri)
    _ = client
    stub.restore()
  end)

  it("hover round trip leaves payloads with no URI fields untouched", function()
    local stub = stub_vim_system()
    local proxy = require("devcontainer.lsp.proxy")
    local got
    local client = proxy.start(OPTS, {})
    client.request("textDocument/hover", {
      textDocument = { uri = "file:///home/me/proj/src/main.c" },
      position = { line = 0, character = 0 },
    }, function(err, result) got = { err = err, result = result } end)
    local outbound = decode_last_written(stub)
    assert.are.equal("file:///workspaces/proj/src/main.c", outbound.params.textDocument.uri)
    local response = {
      jsonrpc = "2.0",
      id = outbound.id,
      result = { contents = { kind = "plaintext", value = "hello" } },
    }
    stub.opts.stdout(nil, frame(vim.json.encode(response)))
    vim.wait(200, function() return got ~= nil end, 5)
    assert.is_not_nil(got)
    assert.are.equal("hello", got.result.contents.value)
    stub.restore()
  end)

  it("definition response with LocationLink[] rewrites targetUri", function()
    local stub = stub_vim_system()
    local proxy = require("devcontainer.lsp.proxy")
    local got
    local client = proxy.start(OPTS, {})
    client.request("textDocument/definition", {
      textDocument = { uri = "file:///home/me/proj/src/main.c" },
      position = { line = 0, character = 0 },
    }, function(err, result) got = { err = err, result = result } end)
    local outbound = decode_last_written(stub)
    local response = {
      jsonrpc = "2.0",
      id = outbound.id,
      result = {
        {
          targetUri = "file:///usr/include/stdio.h",
          targetRange = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
          targetSelectionRange = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
        },
      },
    }
    stub.opts.stdout(nil, frame(vim.json.encode(response)))
    vim.wait(200, function() return got ~= nil end, 5)
    assert.is_not_nil(got)
    assert.are.equal("docker://abc123/usr/include/stdio.h", got.result[1].targetUri)
    stub.restore()
  end)

  it("returns a closing client and dispatches on_error if container is not running", function()
    require("devcontainer.container").state = {
      container_id = nil, remote_workspace_folder = nil, remote_user = nil,
      running = false, last_outcome = nil,
    }
    local stub = stub_vim_system()
    local proxy = require("devcontainer.lsp.proxy")
    local err_seen
    local client = proxy.start(OPTS, {
      on_error = function(_, e) err_seen = e end,
    })
    vim.wait(200, function() return err_seen ~= nil end, 5)
    assert.is_not_nil(err_seen)
    assert.is_true(client.is_closing())
    assert.is_nil(stub.argv, "vim.system should not be called when container is not running")
    stub.restore()
  end)

  it("builds argv as `devcontainer exec --workspace-folder <ws> <server>`", function()
    local stub = stub_vim_system()
    local proxy = require("devcontainer.lsp.proxy")
    proxy.start(OPTS, {})
    assert.are.equal("devcontainer", stub.argv[1])
    assert.are.equal("exec", stub.argv[2])
    assert.are.equal("--workspace-folder", stub.argv[3])
    assert.are.equal("/home/me/proj", stub.argv[4])
    assert.are.equal("clangd", stub.argv[5])
    stub.restore()
  end)
end)
