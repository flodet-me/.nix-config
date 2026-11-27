-- Base Neovim config (home/flodet/_shared/components/neovim, docs/neovim.md).
-- Language servers and formatters come from PATH: the project's dev shell
-- (direnv) first, then the few defaults Nix puts on nvim's own PATH.
-- Projects extend this with a trusted .nvim.lua (see 'exrc').

vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

local o = vim.opt
o.number = true
o.relativenumber = true
o.signcolumn = 'yes'
o.cursorline = true
o.scrolloff = 8
o.splitright = true
o.splitbelow = true
o.ignorecase = true
o.smartcase = true
o.undofile = true
o.clipboard = 'unnamedplus'
o.updatetime = 250
o.list = true
o.listchars = { tab = '» ', trail = '·', nbsp = '␣' }
o.foldlevelstart = 99
o.completeopt = { 'menu', 'menuone', 'noselect', 'popup' }
-- Project config: .nvim.lua in the working directory and its parents, only
-- after `:trust` (Neovim asks on first sight and after every change).
o.exrc = true

vim.diagnostic.config({
  severity_sort = true,
  virtual_text = { current_line = true },
  float = { border = 'rounded', source = true },
})

-- UI and editing helpers
require('mini.icons').setup()
MiniIcons.mock_nvim_web_devicons()
require('mini.statusline').setup()
require('mini.pairs').setup()
require('mini.surround').setup()
require('mini.ai').setup()
require('gitsigns').setup()
require('which-key').setup({ preset = 'helix' })

local fzf = require('fzf-lua')
fzf.setup({})
local map = vim.keymap.set
map('n', '<leader>ff', fzf.files, { desc = 'Find files' })
map('n', '<leader>fg', fzf.live_grep, { desc = 'Grep' })
map('n', '<leader>fb', fzf.buffers, { desc = 'Buffers' })
map('n', '<leader>fh', fzf.helptags, { desc = 'Help' })
map('n', '<leader>fr', fzf.resume, { desc = 'Resume last picker' })
map('n', '<leader>fd', fzf.diagnostics_workspace, { desc = 'Diagnostics' })
map('n', '<leader>fs', fzf.lsp_live_workspace_symbols, { desc = 'Workspace symbols' })
map('n', '<leader>e', vim.diagnostic.open_float, { desc = 'Line diagnostics' })

-- Treesitter: all grammars are installed by Nix; highlight and fold with
-- them where a parser exists, plain Vim syntax elsewhere.
vim.api.nvim_create_autocmd('FileType', {
  callback = function(ev)
    if pcall(vim.treesitter.start, ev.buf) then
      vim.wo[0][0].foldmethod = 'expr'
      vim.wo[0][0].foldexpr = 'v:lua.vim.treesitter.foldexpr()'
    end
  end,
})

-- Completion
require('blink.cmp').setup({
  keymap = { preset = 'default' }, -- <C-y> accept, <C-space> open, <C-n>/<C-p> move
  completion = { documentation = { auto_show = true } },
  signature = { enabled = true },
})
vim.lsp.config('*', { capabilities = require('blink.cmp').get_lsp_capabilities() })

-- Language servers. Definitions come from nvim-lspconfig; a server is enabled
-- once its binary is on PATH, so adding it to a dev shell is all a project
-- needs. Neovim's defaults: K hover, grn rename, gra code action,
-- grr references, gri implementation, gO symbols, [d ]d diagnostics.
local servers = {
  nixd = 'nixd',
  lua_ls = 'lua-language-server',
  bashls = 'bash-language-server',
  rust_analyzer = 'rust-analyzer',
  roslyn_ls = 'roslyn-language-server',
  ts_ls = 'typescript-language-server',
  basedpyright = 'basedpyright-langserver',
  ruff = 'ruff',
  clangd = 'clangd',
  gopls = 'gopls',
  jsonls = 'vscode-json-language-server',
  yamlls = 'yaml-language-server',
  taplo = 'taplo',
  marksman = 'marksman',
}

vim.lsp.config('nixd', { settings = { nixd = { formatting = { command = { 'nixfmt' } } } } })
vim.lsp.config('lua_ls', {
  settings = {
    Lua = {
      runtime = { version = 'LuaJIT' },
      workspace = { library = { vim.env.VIMRUNTIME }, checkThirdParty = false },
    },
  },
})

local function enable_available()
  for name, bin in pairs(servers) do
    if vim.fn.executable(bin) == 1 then
      vim.lsp.enable(name)
    end
  end
end
enable_available()
-- direnv.vim loads a project's environment after startup (nvim started
-- outside the project, :cd): pick up the servers its dev shell brought.
vim.api.nvim_create_autocmd('User', { pattern = 'DirenvLoaded', callback = enable_available })

-- Format on save is per project: `vim.g.format_on_save = true` in .nvim.lua.
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(ev)
    local client = vim.lsp.get_client_by_id(ev.data.client_id)
    if not client then
      return
    end
    local opts = function(desc)
      return { buffer = ev.buf, desc = desc }
    end
    map('n', 'gd', vim.lsp.buf.definition, opts('Go to definition'))
    map('n', 'gD', vim.lsp.buf.declaration, opts('Go to declaration'))
    map({ 'n', 'x' }, '<leader>cf', function()
      vim.lsp.buf.format({ async = true })
    end, opts('Format'))
    map('n', '<leader>ch', function()
      vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled({ bufnr = ev.buf }), { bufnr = ev.buf })
    end, opts('Toggle inlay hints'))
    if client:supports_method('textDocument/formatting') then
      vim.api.nvim_create_autocmd('BufWritePre', {
        buffer = ev.buf,
        group = vim.api.nvim_create_augroup('format-on-save-' .. ev.buf, { clear = true }),
        callback = function()
          if vim.g.format_on_save then
            vim.lsp.buf.format({ bufnr = ev.buf, timeout_ms = 2000 })
          end
        end,
      })
    end
  end,
})
