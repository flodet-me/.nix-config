# Config of every home-manager user on every machine. Username and home
# directory come from the NixOS user (flake.nix: host.user).
{ ... }:
{
  imports = [
    ./components/zsh.nix
    ./components/bash.nix
    ./components/bat.nix
    ./components/direnv.nix
    ./components/fzf.nix
    ./components/neovim
    ./components/git
    ./components/nix-config-checkout.nix
  ];

  programs.home-manager.enable = true;
}
