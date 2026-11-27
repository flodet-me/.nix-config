{
  programs.git = {
    enable = true;
    lfs = {
      enable = true;
    };
    # ~/.config/git/ignore, for every repository
    ignores = [
      ".direnv/"
      "result"
      "result-*"
      ".envrc.local"
      "*.swp"
      "*~"
      ".DS_Store"
    ];
    includes = [
      {
        path = ./gitconfig;
      }
    ];
  };

  # Pager for git diff/log/show/blame and `add -p`; other commands keep core.pager (gitconfig)
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options.navigate = true; # n/N jump between files
  };
}
