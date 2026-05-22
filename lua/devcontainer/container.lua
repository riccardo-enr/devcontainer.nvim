--[==[
Async wrapper around `devcontainer up`.

Spawns the CLI via `vim.system`, streams output into the
[[DevcontainerLog buffer]], and parses the JSON outcome into a
[[container state]] cached at module scope.
]==]

local M = {}

M.state = {
	container_id = nil,
	remote_workspace_folder = nil,
	remote_user = nil,
	running = false,
	last_outcome = nil,
}

--- Scan a stdout blob for the last balanced top-level JSON object and decode it.
---@param stdout string
---@return table?
local function parse_outcome(stdout)
	if not stdout or stdout == "" then
		return nil
	end
	local depth, start = 0, nil
	local last_obj
	for i = 1, #stdout do
		local c = stdout:sub(i, i)
		if c == "{" then
			if depth == 0 then
				start = i
			end
			depth = depth + 1
		elseif c == "}" then
			depth = depth - 1
			if depth == 0 and start then
				last_obj = stdout:sub(start, i)
				start = nil
			end
		end
	end
	if not last_obj then
		return nil
	end
	local ok, decoded = pcall(vim.json.decode, last_obj)
	if not ok then
		return nil
	end
	return decoded
end

local function notify(msg, level)
	vim.schedule(function()
		vim.notify("devcontainer.nvim: " .. msg, level)
	end)
end

local function tail(s, n)
	local lines = vim.split(s or "", "\n", { plain = true })
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	local from = math.max(1, #lines - n + 1)
	return table.concat({ unpack(lines, from) }, "\n")
end

--- Map common failure shapes to actionable hints.
---@param stderr string
---@param outcome table?
---@return string
local function diagnose(stderr, outcome)
	if outcome and outcome.message then
		return tostring(outcome.message)
	end
	local s = stderr or ""
	if s:find("command not found", 1, true) or s:find("ENOENT", 1, true) then
		return "`devcontainer` CLI not found on $PATH. install `@devcontainers/cli`."
	end
	if s:find("Dev container config", 1, true) and s:find("not found", 1, true) then
		return "no devcontainer.json. create `.devcontainer/devcontainer.json`."
	end
	local t = tail(s, 10)
	if t ~= "" then
		return t
	end
	return "devcontainer CLI exited with non-zero status"
end

--- Build argv for `devcontainer up`.
---@param rebuild boolean
---@return string[]
local function build_argv(rebuild)
	local main = require("devcontainer")
	local cfg = main.config or {}
	local cli = cfg.cli or "devcontainer"
	local cfg_mod = require("devcontainer.config")
	local ws = cfg_mod.workspace_folder()
	local argv = { cli, "up", "--workspace-folder", ws }
	local selected = cfg_mod.find_config()
	if selected and cfg_mod.is_variant(selected) then
		table.insert(argv, "--config")
		table.insert(argv, selected)
	end
	if rebuild then
		table.insert(argv, "--remove-existing-container")
		table.insert(argv, "--build-no-cache")
	end
	return argv
end

--- Start (or reuse) the devcontainer for the current workspace.
---@param opts? { rebuild?: boolean, on_exit?: fun(state: table, err: string?) }
function M.up(opts)
	opts = opts or {}
	local on_exit = opts.on_exit or function() end
	local fired = false
	local function fire(state, err)
		if fired then
			return
		end
		fired = true
		vim.schedule(function()
			on_exit(state, err)
		end)
	end

	local argv = build_argv(opts.rebuild)
	local logbuf = require("devcontainer.buffer")
	logbuf.reset()
	logbuf.open()
	logbuf.append({ "$ " .. table.concat(argv, " ") })

	local stdout_acc, stderr_acc = {}, {}

	local ok, _ = pcall(vim.system, argv, {
		text = true,
		stdout = function(_, data)
			if data and data ~= "" then
				table.insert(stdout_acc, data)
				logbuf.append(data)
			end
		end,
		stderr = function(_, data)
			if data and data ~= "" then
				table.insert(stderr_acc, data)
				logbuf.append(data)
			end
		end,
	}, function(res)
		local stdout = table.concat(stdout_acc, "")
		local stderr = table.concat(stderr_acc, "")
		if res and res.stdout and stdout == "" then
			stdout = res.stdout
		end
		if res and res.stderr and stderr == "" then
			stderr = res.stderr
		end

		local outcome = parse_outcome(stdout)
		local code = res and res.code or 0

		if code == 0 and outcome and outcome.outcome == "success" then
			M.state = {
				container_id = outcome.containerId or outcome.container_id,
				remote_workspace_folder = outcome.remoteWorkspaceFolder or outcome.remote_workspace_folder,
				remote_user = outcome.remoteUser or outcome.remote_user,
				running = true,
				last_outcome = "success",
			}
			local short = (M.state.container_id or ""):sub(1, 12)
			notify("started " .. short, vim.log.levels.INFO)
			fire(M.state, nil)
		else
			M.state.running = false
			M.state.last_outcome = outcome and outcome.outcome or "error"
			local msg = diagnose(stderr, outcome)
			notify(msg, vim.log.levels.ERROR)
			fire(M.state, msg)
		end
	end)

	if not ok then
		local msg = "`devcontainer` CLI not found on $PATH. install `@devcontainers/cli`."
		notify(msg, vim.log.levels.ERROR)
		fire(M.state, msg)
	end
end

--- Report current container status.
---@param opts? { on_exit?: fun(state: table, err: string?) }
function M.status(opts)
	opts = opts or {}
	local on_exit = opts.on_exit or function() end
	if M.state.container_id then
		vim.schedule(function()
			on_exit(M.state, nil)
		end)
		return
	end
	M.up({ on_exit = on_exit })
end

return M
