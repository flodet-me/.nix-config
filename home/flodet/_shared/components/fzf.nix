{
  programs.fzf = {
    enable = true;
    # Was set by oh-my-zsh's fzf plugin; zsh loads fzf itself now (zsh.nix)
    defaultCommand = "fd --type f --hidden --exclude .git";
  };
}
