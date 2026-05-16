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
end

return M
