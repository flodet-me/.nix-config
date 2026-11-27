{ config, ... }:
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
      # command-and-control's agent worktrees commit as the agent, unsigned (after gitconfig: last one wins).
      # Inline, so git reads nothing from inside the repository the agent can write to.
      {
        condition = "gitdir:${config.home.homeDirectory}/Projects/command-and-control/.bare/worktrees/agent-*";
        contents = {
          user = {
            name = "Claude agent";
            email = "noreply@anthropic.com";
          };
          commit.gpgsign = false;
          tag.gpgSign = false;
        };
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
