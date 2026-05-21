--[=[
Template catalog + scaffold for `:DevcontainerTemplate`.

Sources the [[template catalog]] from `devcontainers/templates` via the
GitHub REST tree API, caches the index + each template's `.devcontainer/`
tree to disk (see [[templates cache]]), and scaffolds the chosen template
into `<workspace>/.devcontainer/`.

Public API (all callback-based, async):

  templates.list(opts, cb)
    opts.force_refresh : boolean
    cb(entries, err)   entries = { { id, name, description, files }, ... }

  templates.apply(id, target_root, opts, cb)
    opts.force         : boolean
    cb(written, err)   written = { absolute_path, ... }

Test seams (mutate before calling):
  templates._cache_root   override cache directory
  templates._http         injected HTTP client with `.get(url, cb)`

See ADR-0008 for the design rationale.
]=]

local M = {}

local TTL_SECONDS = 24 * 3600
local TREE_URL = "https://api.github.com/repos/devcontainers/templates/git/trees/main?recursive=1"
local RAW_BASE = "https://raw.githubusercontent.com/devcontainers/templates/main/"

M._cache_root = nil ---@type string?
M._http = nil ---@type table?

local function http()
  return M._http or require("devcontainer.http")
end

local function cache_root()
  if M._cache_root then return M._cache_root end
  return vim.fn.stdpath("cache") .. "/devcontainer.nvim/templates"
end

function M.cache_dir() return cache_root() end

local function mkdir_p(path)
  vim.fn.mkdir(path, "p")
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(path, content)
  mkdir_p(vim.fs.dirname(path))
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(content)
  f:close()
  return true
end

local function read_catalog()
  local raw = read_file(cache_root() .. "/catalog.json")
  if not raw then return nil end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then return nil end
  return decoded
end

local function is_fresh(catalog)
  if not catalog or type(catalog.fetched_at) ~= "number" then return false end
  return (os.time() - catalog.fetched_at) < TTL_SECONDS
end

local function strip_files(entries)
  local out = {}
  for _, e in ipairs(entries) do
    table.insert(out, {
      id = e.id,
      name = e.name,
      description = e.description,
      files = e.files,
    })
  end
  return out
end

--- Parse the recursive tree JSON and produce a map:
---   id -> { metadata_path, files = { relpath_under_devcontainer, ... } }
local function collect_templates_from_tree(tree)
  local by_id = {}
  for _, entry in ipairs(tree or {}) do
    if entry.type == "blob" and type(entry.path) == "string" then
      local id, rest = entry.path:match("^src/([^/]+)/(.+)$")
      if id then
        local bucket = by_id[id] or { files = {} }
        if rest == "devcontainer-template.json" then
          bucket.metadata_path = entry.path
        else
          local rel = rest:match("^%.devcontainer/(.+)$")
          if rel then
            table.insert(bucket.files, rel)
          end
        end
        by_id[id] = bucket
      end
    end
  end
  -- Drop entries without metadata or without any .devcontainer/ files.
  local clean = {}
  for id, bucket in pairs(by_id) do
    if bucket.metadata_path and #bucket.files > 0 then
      table.sort(bucket.files)
      clean[id] = bucket
    end
  end
  return clean
end

--- Fetch + persist the entire catalog. cb(entries, err).
local function refresh(cb)
  http().get(TREE_URL, function(body, err)
    if err then return cb(nil, err) end
    local ok, tree_resp = pcall(vim.json.decode, body)
    if not ok or type(tree_resp) ~= "table" or type(tree_resp.tree) ~= "table" then
      return cb(nil, "malformed tree response")
    end
    local templates = collect_templates_from_tree(tree_resp.tree)

    local ids = {}
    for id, _ in pairs(templates) do table.insert(ids, id) end
    table.sort(ids)

    if #ids == 0 then return cb(nil, "no templates found in tree") end

    local entries = {}
    local remaining = 0
    local errored = nil

    local function maybe_finish()
      if errored or remaining > 0 then return end
      table.sort(entries, function(a, b) return a.id < b.id end)
      local catalog = { fetched_at = os.time(), entries = entries }
      write_file(cache_root() .. "/catalog.json", vim.json.encode(catalog))
      cb(strip_files(entries), nil)
    end

    for _, id in ipairs(ids) do
      local bucket = templates[id]
      remaining = remaining + 1 -- metadata fetch
      http().get(RAW_BASE .. bucket.metadata_path, function(meta_body, meta_err)
        if errored then return end
        if meta_err then errored = meta_err; return cb(nil, meta_err) end
        local meta_ok, meta = pcall(vim.json.decode, meta_body)
        if not meta_ok or type(meta) ~= "table" then
          errored = "malformed metadata for " .. id
          return cb(nil, errored)
        end
        local entry = {
          id = id,
          name = meta.name or id,
          description = meta.description or "",
          files = bucket.files,
        }
        table.insert(entries, entry)

        -- Fetch each .devcontainer/<file> for this template.
        for _, rel in ipairs(bucket.files) do
          remaining = remaining + 1
          local url = RAW_BASE .. "src/" .. id .. "/.devcontainer/" .. rel
          http().get(url, function(file_body, file_err)
            if errored then return end
            if file_err then errored = file_err; return cb(nil, file_err) end
            write_file(cache_root() .. "/" .. id .. "/" .. rel, file_body)
            remaining = remaining - 1
            maybe_finish()
          end)
        end
        remaining = remaining - 1 -- metadata done
        maybe_finish()
      end)
    end
  end)
end

function M.list(opts, cb)
  opts = opts or {}
  local cached = read_catalog()
  if not opts.force_refresh and is_fresh(cached) then
    return cb(strip_files(cached.entries), nil)
  end
  refresh(function(entries, err)
    if not err then return cb(entries, nil) end
    if cached and cached.entries then
      vim.notify(
        "devcontainer.nvim: using stale catalog (" .. err .. ")",
        vim.log.levels.WARN)
      return cb(strip_files(cached.entries), nil)
    end
    cb(nil, err)
  end)
end

local function workspace_has_devcontainer(target_root)
  return vim.uv.fs_stat(target_root .. "/.devcontainer") ~= nil
    or vim.uv.fs_stat(target_root .. "/.devcontainer.json") ~= nil
end

function M.apply(id, target_root, opts, cb)
  opts = opts or {}
  local cached = read_catalog()
  if not cached or type(cached.entries) ~= "table" then
    return cb(nil, "no cached catalog; run :DevcontainerTemplate first")
  end
  local entry
  for _, e in ipairs(cached.entries) do
    if e.id == id then entry = e; break end
  end
  if not entry then
    return cb(nil, "unknown template id: " .. tostring(id))
  end

  if not opts.force and workspace_has_devcontainer(target_root) then
    return cb(nil,
      ".devcontainer/ already exists at " .. target_root ..
      " (pass { force = true } to overwrite)")
  end

  local written = {}
  for _, rel in ipairs(entry.files or {}) do
    local src = cache_root() .. "/" .. id .. "/" .. rel
    local content = read_file(src)
    if not content then
      return cb(nil, "missing cached file: " .. src)
    end
    local dst = target_root .. "/.devcontainer/" .. rel
    local ok, werr = write_file(dst, content)
    if not ok then return cb(nil, "write failed: " .. tostring(werr)) end
    table.insert(written, dst)
  end
  cb(written, nil)
end

return M
