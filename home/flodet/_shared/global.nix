# This file (and the global directory) holds config that i use on all home manager
{
  inputs,
  outputs,
  pkgs,
  ...
}:
{
  home.username = "flodet";
  home.homeDirectory = "/home/flodet";

  imports = [
    ./components/zsh.nix
    ./components/bash.nix
    ./components/bat.nix
    ./components/direnv.nix
    ./components/fzf.nix
    ./components/tmux.nix
    ./components/git/default.nix
    ./nixpkgs.nix
  ];

  home.packages = with pkgs; [
    nvim
  ];

  nix.package = pkgs.nix;

  programs.home-manager.enable = true;
}
