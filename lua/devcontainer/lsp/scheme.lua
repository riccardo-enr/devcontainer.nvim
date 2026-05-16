--[==[
Host-side resolver for the [[docker:// scheme]].

When the [[RPC proxy]] rewrites a container-only path (a system header,
language runtime, dependency cache) into `docker://<container_id>/<abs>`
and the user jumps to that URI, this `BufReadCmd` autocmd fetches the file
via `docker exec <id> cat <abs>` and fills a readonly scratch buffer with
the result. Editing is disallowed by design: container state is ephemeral.
]==]

local M = {}

local AUGROUP = "devcontainer_docker_scheme"

function M._parse(uri)
  local id, rest = uri:match("^docker://([^/]+)/(.*)$")
  if not id then return nil end
  return id, "/" .. rest
end

function M.read(bufnr, uri)
  local id, abs = M._parse(uri)
  if not id then return false end
  local res = vim.system({ "docker", "exec", id, "cat", abs }, { text = true }):wait()
  if (res.code or 0) ~= 0 then
    vim.notify(
      "devcontainer.nvim: failed to read " .. uri .. ": " .. (res.stderr or ""),
      vim.log.levels.ERROR
    )
    return false
  end
  local lines = vim.split(res.stdout or "", "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modifiable = false
  local ft = vim.filetype.match({ filename = abs })
  if ft and ft ~= "" then vim.bo[bufnr].filetype = ft end
  return true
end

function M.setup()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "docker://*",
    callback = function(args)
      M.read(args.buf, args.match)
    end,
  })
end

return M
