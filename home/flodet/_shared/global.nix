# This file (and the global directory) holds config that i use on all home manager 
{
  inputs,
  outputs,
  ...
}:
{
  imports = [
    ./components/zsh.nix
    ./components/bash.nix
    ./components/tmux.nix
    ./components/git/default.nix
  ];
}
