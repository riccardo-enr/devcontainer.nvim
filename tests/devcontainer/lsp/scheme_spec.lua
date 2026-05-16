-- Specs for lua/devcontainer/lsp/scheme.lua
--
-- The module registers a BufReadCmd autocmd for docker:// URIs, fetching the
-- file from inside the container via `docker exec <id> cat <abs>` and
-- presenting it readonly. vim.system is stubbed to drive deterministic
-- output.

local function reset()
  package.loaded["devcontainer.lsp.scheme"] = nil
end

local function stub_vim_system(result)
  local captured = { argv = nil }
  local original = vim.system
  vim.system = function(argv, _opts)
    captured.argv = argv
    return {
      wait = function()
        return {
          code = result.code or 0,
          stdout = result.stdout or "",
          stderr = result.stderr or "",
        }
      end,
    }
  end
  captured.restore = function() vim.system = original end
  return captured
end

local function new_buf()
  return vim.api.nvim_create_buf(false, true)
end

describe("devcontainer.lsp.scheme", function()
  before_each(reset)

  it("parses docker://<id>/<abs> into id and absolute container path", function()
    local scheme = require("devcontainer.lsp.scheme")
    local id, abs = scheme._parse("docker://abc123/usr/include/stdio.h")
    assert.are.equal("abc123", id)
    assert.are.equal("/usr/include/stdio.h", abs)
  end)

  it("fills the buffer with `docker exec <id> cat <abs>` output", function()
    local stub = stub_vim_system({ stdout = "line one\nline two\n", code = 0 })
    local scheme = require("devcontainer.lsp.scheme")
    local bufnr = new_buf()
    local ok = scheme.read(bufnr, "docker://abc/usr/include/foo.h")
    assert.is_true(ok)
    assert.are.same({ "docker", "exec", "abc", "cat", "/usr/include/foo.h" }, stub.argv)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.are.same({ "line one", "line two" }, lines)
    stub.restore()
  end)

  it("marks the buffer readonly, nofile, nomodifiable", function()
    local stub = stub_vim_system({ stdout = "x\n", code = 0 })
    local scheme = require("devcontainer.lsp.scheme")
    local bufnr = new_buf()
    scheme.read(bufnr, "docker://abc/etc/hostname")
    assert.are.equal("nofile", vim.bo[bufnr].buftype)
    assert.is_true(vim.bo[bufnr].readonly)
    assert.is_false(vim.bo[bufnr].modifiable)
    stub.restore()
  end)

  it("sets filetype from the container path extension", function()
    local stub = stub_vim_system({ stdout = "#include <x>\n", code = 0 })
    local scheme = require("devcontainer.lsp.scheme")
    local bufnr = new_buf()
    scheme.read(bufnr, "docker://abc/script.py")
    assert.are.equal("python", vim.bo[bufnr].filetype)
    stub.restore()
  end)

  it("returns false and does not touch the buffer on non-zero exit", function()
    local stub = stub_vim_system({ stdout = "", stderr = "no such file", code = 1 })
    local scheme = require("devcontainer.lsp.scheme")
    local bufnr = new_buf()
    local ok = scheme.read(bufnr, "docker://abc/missing")
    assert.is_false(ok)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.are.same({ "" }, lines)
    stub.restore()
  end)

  it("setup registers a BufReadCmd autocmd for docker://*", function()
    local scheme = require("devcontainer.lsp.scheme")
    scheme.setup()
    local autos = vim.api.nvim_get_autocmds({ event = "BufReadCmd", pattern = "docker://*" })
    assert.is_true(#autos >= 1)
  end)
end)
