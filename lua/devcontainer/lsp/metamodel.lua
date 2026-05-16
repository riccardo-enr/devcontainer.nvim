--[==[
Build the [[metaModel lookup table]] from the vendored LSP `metaModel.json`.

For every JSON-RPC method, return three lists of JSON-path descriptors
pointing at URI / DocumentUri leaves inside `params`, `result`, and
`partialResult` respectively. The [[RPC proxy]] feeds these to
`uri_map.apply` so URI fields are visited by precomputed paths instead of a
recursive scan of unknown JSON.

Path descriptors have the form `{ segments = { "key", "[*]", "key", ... } }`.
The literal segment `"[*]"` means "for each array element".

Limitations recorded here on purpose:

  * Map types (`{ [DocumentUri]: ... }`, e.g. `WorkspaceEdit.changes`) are
    not modelled — the path notation has no "every key" wildcard. The four
    acceptance-criteria methods don't use map-keyed URIs.
  * Recursive structures stop expanding the second time a struct name is
    encountered on the same descent (a conservative depth guard, not a
    correctness issue for finite payloads).
]==]

local M = {}

local cached_model = nil
local cached_lookup = nil

local function model_path()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  return src:gsub("/[^/]+$", "/metaModel.json")
end

function M.load()
  if cached_model then return cached_model end
  local f, err = io.open(model_path(), "r")
  if not f then error("devcontainer.lsp.metamodel: cannot open metaModel.json: " .. tostring(err)) end
  local raw = f:read("*a")
  f:close()
  cached_model = vim.json.decode(raw)
  return cached_model
end

--- Build name -> structure / typeAlias / enumeration indexes once.
local function build_indexes(model)
  local structs, aliases, enums = {}, {}, {}
  for _, s in ipairs(model.structures or {}) do structs[s.name] = s end
  for _, a in ipairs(model.typeAliases or {}) do aliases[a.name] = a end
  for _, e in ipairs(model.enumerations or {}) do enums[e.name] = e end
  return structs, aliases, enums
end

local walk
local walk_struct

local function copy_segments(segs)
  local out = {}
  for i = 1, #segs do out[i] = segs[i] end
  return out
end

walk_struct = function(struct, segs, visited, ctx, out)
  if not struct then return end
  local name = struct.name
  if name then
    if visited[name] then return end
    visited = vim.tbl_extend("force", visited, { [name] = true })
  end
  for _, base in ipairs(struct.extends or {}) do
    walk(base, segs, visited, ctx, out)
  end
  for _, mix in ipairs(struct.mixins or {}) do
    walk(mix, segs, visited, ctx, out)
  end
  for _, prop in ipairs(struct.properties or {}) do
    local next_segs = copy_segments(segs)
    next_segs[#next_segs + 1] = prop.name
    walk(prop.type, next_segs, visited, ctx, out)
  end
end

--- Walk a metaModel type description, accumulating URI-leaf paths into `out`.
---@param t table  metaModel type (kind + payload)
---@param segs string[]  segments accumulated so far
---@param visited table<string, boolean>  struct/alias names already entered on this branch
---@param ctx { structs: table, aliases: table }
---@param out table  accumulator: list of { segments = {...} }
walk = function(t, segs, visited, ctx, out)
  if type(t) ~= "table" then return end
  local k = t.kind
  if k == "base" then
    if t.name == "URI" or t.name == "DocumentUri" then
      out[#out + 1] = { segments = copy_segments(segs) }
    end
    return
  end
  if k == "reference" then
    if visited[t.name] then return end
    local s = ctx.structs[t.name]
    if s then
      walk_struct(s, segs, visited, ctx, out)
      return
    end
    local a = ctx.aliases[t.name]
    if a then
      local next_visited = vim.tbl_extend("force", visited, { [t.name] = true })
      walk(a.type, segs, next_visited, ctx, out)
      return
    end
    -- enumerations and unknown names: not URI carriers
    return
  end
  if k == "array" then
    local next_segs = copy_segments(segs)
    next_segs[#next_segs + 1] = "[*]"
    walk(t.element, next_segs, visited, ctx, out)
    return
  end
  if k == "or" or k == "and" then
    for _, item in ipairs(t.items or {}) do
      walk(item, segs, visited, ctx, out)
    end
    return
  end
  if k == "literal" then
    -- Inline struct. metaModel shape: { kind='literal', value={ properties = {...} } }
    walk_struct(t.value, segs, visited, ctx, out)
    return
  end
  if k == "tuple" then
    for idx, item in ipairs(t.items or {}) do
      local next_segs = copy_segments(segs)
      next_segs[#next_segs + 1] = tostring(idx)
      walk(item, next_segs, visited, ctx, out)
    end
    return
  end
  -- map / stringLiteral / integerLiteral / booleanLiteral: skipped (see header).
end

--- Deduplicate by joined segment key.
local function dedup(paths)
  local seen, out = {}, {}
  for _, p in ipairs(paths) do
    local k = table.concat(p.segments, "/")
    if not seen[k] then
      seen[k] = true
      out[#out + 1] = p
    end
  end
  return out
end

local function paths_for(type_obj, ctx)
  if not type_obj then return {} end
  local out = {}
  walk(type_obj, {}, {}, ctx, out)
  return dedup(out)
end

local function build_lookup(model)
  local structs, aliases, enums = build_indexes(model)
  local ctx = { structs = structs, aliases = aliases, enums = enums }
  local lookup = {}
  local function add(entry)
    lookup[entry.method] = {
      params = paths_for(entry.params, ctx),
      result = paths_for(entry.result, ctx),
      partialResult = paths_for(entry.partialResult, ctx),
    }
  end
  for _, r in ipairs(model.requests or {}) do add(r) end
  for _, n in ipairs(model.notifications or {}) do add(n) end
  return lookup
end

local EMPTY = { params = {}, result = {}, partialResult = {} }

function M.lookup_for(method)
  if not cached_lookup then
    cached_lookup = build_lookup(M.load())
  end
  return cached_lookup[method] or EMPTY
end

--- Test hook: reset cached state.
function M._reset()
  cached_model = nil
  cached_lookup = nil
end

return M
