--[[
Tiny async HTTP GET wrapper. Prefers `vim.net.request` when present
(Neovim 0.11+); otherwise shells out to `curl -fsSL` via `vim.system`.

API:
  M.get(url, cb) -- cb(body, err); exactly one of body / err is non-nil.

Callbacks always fire on the main loop (via vim.schedule).
]]

local M = {}

local function has_vim_net()
  return type(vim.net) == "table" and type(vim.net.request) == "function"
end

local function via_vim_net(url, cb)
  vim.net.request(url, {}, function(err, response)
    vim.schedule(function()
      if err then
        cb(nil, tostring(err))
      else
        cb(response and response.body or "", nil)
      end
    end)
  end)
end

local function via_curl(url, cb)
  vim.system(
    { "curl", "-fsSL", url },
    { text = true },
    function(out)
      vim.schedule(function()
        if out.code ~= 0 then
          local stderr = (out.stderr or ""):gsub("%s+$", "")
          cb(nil, "curl exit " .. tostring(out.code) ..
            (stderr ~= "" and (": " .. stderr) or ""))
        else
          cb(out.stdout or "", nil)
        end
      end)
    end
  )
end

function M.get(url, cb)
  if has_vim_net() then
    via_vim_net(url, cb)
  else
    via_curl(url, cb)
  end
end

return M
