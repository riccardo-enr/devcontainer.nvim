--[[
DevcontainerLog buffer

A single named scratch split that streams stdout+stderr from async CLI runs.
Owned by `container.lua`. `:DevcontainerLog` re-opens it.
]]

local M = {}

local BUFNAME = "DevcontainerLog"

local state = { bufnr = nil }

local function ensure_buf()
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		return state.bufnr
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "devcontainerlog"
	pcall(vim.api.nvim_buf_set_name, buf, BUFNAME)
	state.bufnr = buf
	return buf
end

--- Open or focus the log split.
function M.open()
	local buf = ensure_buf()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == buf then
			vim.api.nvim_set_current_win(win)
			return buf
		end
	end
	vim.cmd("botright split")
	vim.api.nvim_win_set_buf(0, buf)
	vim.cmd("resize 12")
	return buf
end

--- Clear the buffer before a new run.
function M.reset()
	local buf = ensure_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
end

--- Append lines (string or string[]) to the buffer. Safe to call from any thread.
---@param data string|string[]
function M.append(data)
	vim.schedule(function()
		local buf = ensure_buf()
		local lines
		if type(data) == "string" then
			lines = vim.split(data, "\n", { plain = true })
		else
			lines = data
		end
		-- Trim trailing empty line from split-on-newline of "a\nb\n".
		if #lines > 0 and lines[#lines] == "" then
			table.remove(lines)
		end
		if #lines == 0 then
			return
		end
		local last = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_buf_set_lines(buf, last, last, false, lines)
	end)
end

return M
