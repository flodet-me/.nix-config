{
  config,
  pkgs,
  ...
}:
{
  # zsh-vi-mode rebinds keys on its (lazy) init, which drops fzf's Ctrl-R; fzf is loaded from its hook instead
  programs.fzf.enableZshIntegration = false;

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    shellAliases = {
      ll = "ls -l";
      update = "nh os switch"; # builds and switches this host from ~/.nix-config
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

    # Ctrl-R history, Ctrl-T files, Alt-C cd, **<Tab> completion
    initContent = ''
      zvm_after_init_commands+=(
        'source ${config.programs.fzf.package}/share/fzf/key-bindings.zsh'
        'source ${config.programs.fzf.package}/share/fzf/completion.zsh'
      )
    '';
  };
}
