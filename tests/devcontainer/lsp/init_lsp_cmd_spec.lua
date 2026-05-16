-- Specs for the public lsp_cmd() API on `require('devcontainer')`.
--
-- A tmp directory acts as the workspace; we point the plugin at it via
-- `config.workspace_folder` so we don't have to change cwd (which would
-- break the project-relative package.path used by plenary).

local function reset()
  for k in pairs(package.loaded) do
    if k == "devcontainer" or k:match("^devcontainer%.") then
      package.loaded[k] = nil
    end
  end
end

local function write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

local function fresh_workspace(with_devcontainer)
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  if with_devcontainer then
    write_file(tmp .. "/.devcontainer/devcontainer.json",
      '{ "image": "ubuntu", "workspaceFolder": "/workspaces/proj" }')
  end
  local dc = require("devcontainer")
  dc.config.workspace_folder = tmp
  return tmp, dc
end

describe("devcontainer.lsp_cmd", function()
  before_each(reset)

  it("returns the server argv unchanged when no .devcontainer/ is found", function()
    local _, dc = fresh_workspace(false)
    local argv = { "clangd", "--background-index" }
    local out = dc.lsp_cmd(argv)
    assert.are.same(argv, out)
  end)

  it("returns a function when devcontainer.json exists", function()
    local _, dc = fresh_workspace(true)
    local out = dc.lsp_cmd({ "clangd" })
    assert.are.equal("function", type(out))
  end)

  it("the returned function builds a client with the proxy contract", function()
    local _, dc = fresh_workspace(true)
    require("devcontainer.container").state = {
      container_id = "abc", remote_workspace_folder = "/workspaces/proj",
      remote_user = "vscode", running = true, last_outcome = "success",
    }
    local original = vim.system
    vim.system = function() return { write = function() end, kill = function() end } end
    local client = dc.lsp_cmd({ "clangd" })({})
    vim.system = original
    assert.is_function(client.request)
    assert.is_function(client.notify)
    assert.is_function(client.terminate)
    assert.is_function(client.is_closing)
  end)

  it("registers the docker:// BufReadCmd autocmd when invoked", function()
    pcall(vim.api.nvim_del_augroup_by_name, "devcontainer_docker_scheme")
    local _, dc = fresh_workspace(true)
    dc.lsp_cmd({ "clangd" })
    local autos = vim.api.nvim_get_autocmds({ event = "BufReadCmd", pattern = "docker://*" })
    assert.is_true(#autos >= 1)
  end)
end)
