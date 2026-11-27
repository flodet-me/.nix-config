# Neovim with plugins from nixpkgs (nothing downloads at runtime). Language
# servers come from each project's dev shell through direnv; projects add
# settings in a trusted .nvim.lua. See docs/neovim.md.
{ pkgs, ... }:
{
  # nvim is what gitconfig and the shells call; defaultEditor sets EDITOR/VISUAL
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;

    plugins = with pkgs.vimPlugins; [
      nvim-lspconfig # server definitions only (lsp/*.lua), enabled in init.lua
      nvim-treesitter.withAllGrammars
      blink-cmp
      fzf-lua
      gitsigns-nvim
      which-key-nvim
      direnv-vim # load the project's .envrc when nvim enters it
      mini-nvim # stylix's mini.base16 colors come from here too
    ];

    # Only on nvim's PATH and after it: a project's dev shell wins. Nix and
    # Lua are in every project (flake, .nvim.lua), the rest is for the pickers.
    extraPackages = with pkgs; [
      nixd
      nixfmt
      lua-language-server
      bash-language-server
      shellcheck
      ripgrep
      fd
      fzf
      wl-clipboard
    ];

    initLua = builtins.readFile ./init.lua;
  };
}
