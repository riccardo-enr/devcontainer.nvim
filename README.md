# devcontainer.nvim

Neovim front-end for the [Dev Containers CLI](https://github.com/devcontainers/cli). Bring up, rebuild, and exec into devcontainers without leaving the editor.

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "riccardo/devcontainer.nvim",
  cmd = {
    "DevcontainerUp", "DevcontainerDown", "DevcontainerRebuild",
    "DevcontainerExec", "DevcontainerShell", "DevcontainerStatus",
  },
  opts = {},
}
```

## Configuration

```lua
require("devcontainer").setup({
  cli = "devcontainer",      -- path to the devcontainer CLI binary
  workspace_folder = nil,    -- override workspace folder (defaults to cwd)
  auto_attach = true,        -- focus the terminal split when commands run
})
```

## Commands

| Command | Description |
|---|---|
| `:DevcontainerUp` | Build and start the devcontainer |
| `:DevcontainerRebuild` | Rebuild with `--build-no-cache` and replace the container |
| `:DevcontainerExec <cmd>` | Run a shell command inside the container |
| `:DevcontainerShell` | Open an interactive shell inside the container |
| `:DevcontainerStatus` | Show the resolved `devcontainer.json` path |
| `:DevcontainerDown` | (stub) Stop and remove the container |

## Requirements

- Neovim >= 0.10 (uses `vim.uv`)
- [`@devcontainers/cli`](https://github.com/devcontainers/cli) on `$PATH`
- A `.devcontainer/devcontainer.json` (or `.devcontainer.json`) in the workspace

## License

MIT
