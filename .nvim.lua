-- Project config for Neovim (docs/neovim.md): NixOS and home-manager option
-- completion in nixd. Neovim runs this only after `:trust`.
local root = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
local flake = string.format('(builtins.getFlake %q)', root)
local desktop = flake .. '.nixosConfigurations.desktop'

vim.lsp.config('nixd', {
  settings = {
    nixd = {
      nixpkgs = { expr = desktop .. '.pkgs' },
      options = {
        nixos = { expr = desktop .. '.options' },
        home_manager = { expr = desktop .. '.options.home-manager.users.type.getSubOptions []' },
      },
    },
  },
})
vim.g.format_on_save = true
