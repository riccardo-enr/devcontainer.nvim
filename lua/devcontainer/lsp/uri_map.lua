--[==[
URI [[path mapping]] between host and [[devcontainer]] used by the [[RPC proxy]].

Three pure functions:

  to_container(uri, host_root, container_root)
      Outbound rewrite. A host `file://<host_root>/x` becomes
      `file://<container_root>/x`. Everything else is returned unchanged.

  to_host(uri, host_root, container_root, container_id)
      Inbound rewrite. A container `file://<container_root>/x` becomes
      `file://<host_root>/x`. Any other absolute `file://` URI is rewritten
      to the [[docker:// scheme]] so it can be opened readonly host-side.

  apply(payload, paths, rewrite)
      Visit the URI leaves prescribed by `paths` (built from the LSP
      metaModel) and rewrite them in place. `paths` is a list of
      `{ segments = { "...", "[*]", "..." } }`; `[*]` means "for each
      array element". Missing branches are tolerated silently.
]==]

local M = {}

local FILE_PREFIX = "file://"

local function starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

local function strip_file_scheme(uri)
  return uri:sub(#FILE_PREFIX + 1)
end

function M.to_container(uri, host_root, container_root)
  if type(uri) ~= "string" or not starts_with(uri, FILE_PREFIX) then return uri end
  local path = strip_file_scheme(uri)
  if path == host_root then
    return FILE_PREFIX .. container_root
  end
  if starts_with(path, host_root .. "/") then
    return FILE_PREFIX .. container_root .. path:sub(#host_root + 1)
  end
  return uri
end

function M.to_host(uri, host_root, container_root, container_id)
  if type(uri) ~= "string" or not starts_with(uri, FILE_PREFIX) then return uri end
  local path = strip_file_scheme(uri)
  if path == container_root then
    return FILE_PREFIX .. host_root
  end
  if starts_with(path, container_root .. "/") then
    return FILE_PREFIX .. host_root .. path:sub(#container_root + 1)
  end
  -- foreign container path: escape to docker://
  -- path begins with "/"; drop the leading slash so URI is docker://<id>/<abs>
  local abs = path:gsub("^/+", "")
  return "docker://" .. container_id .. "/" .. abs
end

--- Walk `value` along `segments` starting at index `i`, calling `rewrite`
--- on the final string leaf in-place via its parent table.
---@param parent table
---@param key any  parent[key] is the value to descend into
---@param segments string[]
---@param i integer  index of the next segment to consume
---@param rewrite fun(uri: string): string
local function descend(parent, key, segments, i, rewrite)
  local value = parent[key]
  if value == nil then return end
  if i > #segments then
    if type(value) == "string" then
      parent[key] = rewrite(value)
    end
    return
  end
  local seg = segments[i]
  if seg == "[*]" then
    if type(value) ~= "table" then return end
    for idx = 1, #value do
      descend(value, idx, segments, i + 1, rewrite)
    end
  else
    if type(value) ~= "table" then return end
    descend(value, seg, segments, i + 1, rewrite)
  end
end

function M.apply(payload, paths, rewrite)
  if type(payload) ~= "table" or type(paths) ~= "table" then return payload end
  for _, p in ipairs(paths) do
    local segs = p.segments
    if type(segs) == "table" and #segs > 0 then
      local holder = { __root = payload }
      -- Re-route through a synthetic holder so the leaf at depth 1 can be
      -- rewritten through its parent reference (we can't reassign `payload`).
      local first = segs[1]
      if first == "[*]" then
        if type(payload) == "table" then
          for idx = 1, #payload do
            descend(payload, idx, segs, 2, rewrite)
          end
        end
      else
        descend(payload, first, segs, 2, rewrite)
      end
      _ = holder
    end
  end
  return payload
end

return M
