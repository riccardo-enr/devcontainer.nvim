-- Headless bootstrap for plenary.busted. Adds plenary and the plugin under test
-- to the runtimepath so `:PlenaryBustedDirectory` can execute the specs.

local plenary = vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")
vim.opt.runtimepath:append(plenary)
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.cmd("runtime plugin/plenary.vim")
