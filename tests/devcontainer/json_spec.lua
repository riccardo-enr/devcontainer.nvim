local json = require("devcontainer.json")

describe("devcontainer.json.decode", function()
  it("strips // line comments", function()
    local t, err = json.decode([[
      {
        // a leading comment
        "image": "alpine" // trailing
      }
    ]])
    assert.is_nil(err)
    assert.are.equal("alpine", t.image)
  end)

  it("strips /* block */ comments", function()
    local t, err = json.decode([[/* hi */ { "image": /* mid */ "alpine" }]])
    assert.is_nil(err)
    assert.are.equal("alpine", t.image)
  end)

  it("preserves // inside string values", function()
    local t, err = json.decode([[{ "url": "https://example.com//path" }]])
    assert.is_nil(err)
    assert.are.equal("https://example.com//path", t.url)
  end)

  it("strips trailing commas in objects and arrays", function()
    local t, err = json.decode([[{ "a": [1, 2, 3,], "b": "x", }]])
    assert.is_nil(err)
    assert.are.same({ 1, 2, 3 }, t.a)
    assert.are.equal("x", t.b)
  end)

  it("returns an error for malformed JSON", function()
    local t, err = json.decode([[{ "a": ]])
    assert.is_nil(t)
    assert.is_not_nil(err)
  end)
end)

describe("devcontainer.json.substitute", function()
  local env = { localWorkspaceFolder = "/home/u/proj", containerWorkspaceFolder = "/workspaces/proj" }

  it("resolves ${localWorkspaceFolder}", function()
    assert.are.equal("/home/u/proj/x", json.substitute("${localWorkspaceFolder}/x", env))
  end)

  it("resolves ${containerWorkspaceFolder}", function()
    assert.are.equal("/workspaces/proj/y", json.substitute("${containerWorkspaceFolder}/y", env))
  end)

  it("resolves ${localEnv:VAR} from environment", function()
    vim.fn.setenv("DC_NVIM_TEST_VAR", "hello")
    assert.are.equal("hello-world", json.substitute("${localEnv:DC_NVIM_TEST_VAR}-world", env))
  end)

  it("returns empty string for unset ${localEnv:VAR}", function()
    vim.fn.setenv("DC_NVIM_UNSET_VAR", nil)
    assert.are.equal("x--y", json.substitute("x-${localEnv:DC_NVIM_UNSET_VAR}-y", env))
  end)

  it("walks tables recursively", function()
    local out = json.substitute({
      a = "${localWorkspaceFolder}",
      b = { "${containerWorkspaceFolder}", "literal" },
    }, env)
    assert.are.equal("/home/u/proj", out.a)
    assert.are.equal("/workspaces/proj", out.b[1])
    assert.are.equal("literal", out.b[2])
  end)
end)

describe("devcontainer.json.parse", function()
  local tmpfile = function(content)
    local p = vim.fn.tempname() .. ".json"
    local f = assert(io.open(p, "w"))
    f:write(content)
    f:close()
    return p
  end

  it("defaults workspaceFolder to /workspaces/<basename> when missing", function()
    local p = tmpfile([[{ "image": "alpine" }]])
    local cfg, err = json.parse(p, { localWorkspaceFolder = "/home/u/myproj" })
    assert.is_nil(err)
    assert.are.equal("/workspaces/myproj", cfg.workspaceFolder)
  end)

  it("honours explicit workspaceFolder after substitution", function()
    local p = tmpfile([[{ "workspaceFolder": "/workspaces/${localEnv:DC_NVIM_NAME}" }]])
    vim.fn.setenv("DC_NVIM_NAME", "custom")
    local cfg, err = json.parse(p, { localWorkspaceFolder = "/home/u/myproj" })
    assert.is_nil(err)
    assert.are.equal("/workspaces/custom", cfg.workspaceFolder)
  end)

  it("substitutes ${containerWorkspaceFolder} after resolution", function()
    local p = tmpfile([[{
      "workspaceFolder": "/workspaces/p",
      "runArgs": ["--volume", "${containerWorkspaceFolder}:/mnt"]
    }]])
    local cfg, err = json.parse(p, { localWorkspaceFolder = "/home/u/p" })
    assert.is_nil(err)
    assert.are.equal("/workspaces/p:/mnt", cfg.runArgs[2])
  end)

  it("returns dockerComposeFile field untouched (string)", function()
    local p = tmpfile([[{
      "dockerComposeFile": "docker-compose.yml",
      "service": "app",
      "workspaceFolder": "/workspaces/app"
    }]])
    local cfg, err = json.parse(p, { localWorkspaceFolder = "/home/u/app" })
    assert.is_nil(err)
    assert.are.equal("docker-compose.yml", cfg.dockerComposeFile)
    assert.are.equal("app", cfg.service)
  end)

  it("returns dockerComposeFile field untouched (array)", function()
    local p = tmpfile([[{
      "dockerComposeFile": ["base.yml", "override.yml"],
      "service": "app"
    }]])
    local cfg, err = json.parse(p, { localWorkspaceFolder = "/home/u/app" })
    assert.is_nil(err)
    assert.are.same({ "base.yml", "override.yml" }, cfg.dockerComposeFile)
  end)

  it("returns an error when file does not exist", function()
    local cfg, err = json.parse("/nonexistent/path/devcontainer.json", { localWorkspaceFolder = "/x" })
    assert.is_nil(cfg)
    assert.is_not_nil(err)
  end)
end)
