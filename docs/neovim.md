# Neovim

`home/flodet/_shared/components/neovim/` (imported by `home/flodet/_shared/global.nix`)
sets up Neovim on every home-manager host. All plugins come from nixpkgs;
nothing is downloaded at runtime. The config is `init.lua` next to the module.

## What is in the base

- **LSP:** Neovim's built-in client with the server definitions of
  `nvim-lspconfig`. A server from the list in `init.lua` is enabled as soon as
  its binary is on `PATH`: `nixd`, `lua_ls`, `bashls`, `rust_analyzer`,
  `roslyn_ls` (C#), `ts_ls`, `basedpyright`, `ruff`, `clangd`, `gopls`,
  `jsonls`, `yamlls`, `taplo`, `marksman`.
- **Always available** (on nvim's own `PATH`, after the project's):
  `nixd` + `nixfmt`, `lua-language-server`, `bash-language-server` +
  `shellcheck`, and `ripgrep`, `fd`, `fzf`, `wl-clipboard` for the pickers and
  the clipboard. Claude Code's `home.packages` also put `rust-analyzer`,
  `typescript-language-server` and `csharp-ls` on the user `PATH` on
  workstations.
- **Treesitter** with all grammars (highlighting, folds), **blink.cmp**
  completion with signature help, **fzf-lua** pickers, **gitsigns**,
  **which-key**, `mini.nvim` (statusline, pairs, surround, text objects,
  icons; stylix's colors use `mini.base16`), **direnv.vim**.
- `.editorconfig` is honored by Neovim itself.
- Grammars come from Nix: `:TSInstall` is not used, and `:checkhealth
  nvim-treesitter` errors about `tree-sitter-cli` and a non-writable install
  directory are expected.

Keys (leader is Space; `which-key` shows the rest):

| Key | Action |
| --- | --- |
| `<leader>ff` / `fg` / `fb` / `fh` / `fr` | files, grep, buffers, help, resume picker |
| `<leader>fd` / `fs` | workspace diagnostics, workspace symbols |
| `gd` / `gD` | definition, declaration |
| `K`, `grn`, `gra`, `grr`, `gri`, `gO` | Neovim defaults: hover, rename, code action, references, implementation, symbols |
| `[d` / `]d`, `<leader>e` | previous/next diagnostic, line diagnostics |
| `<leader>cf`, `<leader>ch` | format, toggle inlay hints |
| `<C-space>`, `<C-y>`, `<C-n>`/`<C-p>` | completion: open, accept, move |

## Projects extend it

Every project brings its own tools through its flake and direnv
(`.envrc`: `use flake`):

1. **Server and formatter in the dev shell.** Add the language server to the
   flake's `devShells.default` packages, e.g. `roslyn-ls` and `dotnet-sdk_10`,
   `rust-analyzer` and `cargo`, `basedpyright` and `ruff`. With a server from
   the list above that is all: Neovim started in the project (or `:cd` into
   it, direnv.vim loads the environment) enables it, and the project's version
   wins over a global one.
2. **Settings, other servers, format on save: `.nvim.lua`** in the project
   root, committed. Neovim runs it (`'exrc'`, also from parent directories)
   only after you `:trust` it, and asks again after every change, so read it
   first: it is code. Example:

   ```lua
   vim.lsp.config('rust_analyzer', {
     settings = { ['rust-analyzer'] = { check = { command = 'clippy' } } },
   })
   vim.lsp.enable('csharp_ls')    -- a server outside the default list
   vim.g.format_on_save = true    -- off by default
   ```

   Larger configs can live in `.nvim/lsp/<name>.lua` with
   `vim.opt.runtimepath:append('.nvim')` in `.nvim.lua` (`:help 'exrc'`).

This repository's own `.nvim.lua` points `nixd` at the flake for NixOS and
home-manager option completion and turns on format on save.

## Limits

- A server that already started with a global binary keeps running after
  direnv switches `PATH`; `:lsp restart` (or reopening Neovim in the project)
  picks up the project's version.
- `.nvim.lua` and `.envrc` are code that runs in your editor and shell, outside
  any agent sandbox. Review changes an agent made to them before `:trust` or
  `direnv allow`.
