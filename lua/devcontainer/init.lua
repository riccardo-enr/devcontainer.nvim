local M = {}

---@class DevcontainerConfig
---@field cli string  Path to the devcontainer CLI binary
---@field workspace_folder? string  Override workspace folder (defaults to cwd)
---@field auto_attach boolean  Attach to terminal output buffer on long-running commands
M.config = {
	cli = "devcontainer",
	workspace_folder = nil,
	auto_attach = true,
}

--- Setup devcontainer.nvim with user config
---@param opts? DevcontainerConfig
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.api.nvim_create_user_command("DevcontainerUp", function()
		require("devcontainer.commands").up()
	end, { desc = "Start (build + run) the devcontainer for the current workspace" })

	vim.api.nvim_create_user_command("DevcontainerDown", function()
		require("devcontainer.commands").down()
	end, { desc = "Stop and remove the devcontainer" })

	vim.api.nvim_create_user_command("DevcontainerRebuild", function()
		require("devcontainer.commands").rebuild()
	end, { desc = "Rebuild the devcontainer image" })

	vim.api.nvim_create_user_command("DevcontainerExec", function(args)
		require("devcontainer.commands").exec(args.args)
	end, { nargs = "+", desc = "Run a command inside the devcontainer" })

	vim.api.nvim_create_user_command("DevcontainerShell", function()
		require("devcontainer.commands").shell()
	end, { desc = "Open a shell inside the devcontainer" })

	vim.api.nvim_create_user_command("DevcontainerStatus", function()
		require("devcontainer.commands").status()
	end, { desc = "Show devcontainer status" })

	vim.api.nvim_create_user_command("DevcontainerLog", function()
		require("devcontainer.commands").log()
	end, { desc = "Open the devcontainer.nvim log buffer" })

	vim.api.nvim_create_user_command("DevcontainerTemplate", function()
		local templates = require("devcontainer.templates")
		local config = require("devcontainer.config")
		templates.list({}, function(entries, err)
			if err then
				vim.notify("devcontainer.nvim: " .. err, vim.log.levels.ERROR)
				return
			end
			vim.ui.select(entries, {
				prompt = "Devcontainer template:",
				format_item = function(item)
					return item.name .. (item.description ~= "" and (" - " .. item.description) or "")
				end,
			}, function(choice)
				if not choice then return end
				templates.apply(choice.id, config.workspace_folder(), {}, function(written, apply_err)
					if apply_err then
						vim.notify("devcontainer.nvim: " .. apply_err, vim.log.levels.ERROR)
						return
					end
					vim.notify(
						"devcontainer.nvim: scaffolded " .. choice.id .. " (" .. #written .. " files)",
						vim.log.levels.INFO)
				end)
			end)
		end)
	end, { desc = "Scaffold .devcontainer/ from the official templates catalog" })
end

--- Build the `cmd` value for `vim.lsp.config`. If a `devcontainer.json`
--- exists under the workspace, returns a function that routes the LSP
--- through the in-container server via the [[RPC proxy]]; otherwise
--- returns `server_argv` unchanged so nvim spawns the LSP host-side.
--- See ADR-0006 (fallback) and ADR-0007 (lazy `devcontainer up`).
---@param server_argv string[]
---@return string[] | fun(dispatchers: table): table
function M.lsp_cmd(server_argv)
	local config = require("devcontainer.config")
	if not config.find_config() then return server_argv end

	require("devcontainer.lsp.scheme").setup()

	return function(dispatchers)
		local json = require("devcontainer.json")
		local host_root = config.workspace_folder()
		local parsed = json.load() or {}
		local container_root = parsed.workspaceFolder
			or ("/workspaces/" .. vim.fn.fnamemodify(host_root, ":t"))

		return require("devcontainer.lsp.lazy").start({
			server_argv = server_argv,
			host_root = host_root,
			container_root = container_root,
			workspace_folder = host_root,
		}, dispatchers)
	end
end

return M
