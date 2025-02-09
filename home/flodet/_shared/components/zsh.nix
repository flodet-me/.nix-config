{
  pkgs,
  config,
  ...
}:
{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    initExtra = ''
      if command -v tmux &> /dev/null && [ -z "$TMUX" ]; then
        tmux
      fi

      unset SSH_AGENT_PID
      if [ "$(gnupg_SSH_AUTH_SOCK_by: -0)" -ne $$ ]; then
        export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"
      fi
      export GPG_TTY=$(tty)
      gpg-connect-agent updatestartuptty /bye >/dev/null
    '';

    shellAliases = {
      ll = "ls -l";
      update = "sudo nixos-rebuild switch";
    };
    history.size = 10000;
    history.ignoreAllDups = true;
    history.path = "$HOME/.zsh_history";
    history.ignorePatterns = [
      "rm *"
      "pkill *"
      "cp *"
    ];

    oh-my-zsh = {
      enable = true;
      plugins = [
        "git"
        "fzf"
        "aliases"
        "git-extras"
      ];
      theme = "robbyrussell";
    };

    plugins = [
      {
        name = "vi-mode";
        src = pkgs.zsh-vi-mode;
        file = "share/zsh-vi-mode/zsh-vi-mode.plugin.zsh";
      }

    ];
  };
}
