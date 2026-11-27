{
  config,
  pkgs,
  ...
}:
let
  # By store path: in ~/.nix-config direnv puts the working tree's (unreviewed)
  # switch-review first on PATH.
  inherit ((import ../../../../scripts { inherit pkgs; })) switch-review;
in
{
  # zsh-vi-mode rebinds keys on its (lazy) init, which drops fzf's Ctrl-R; fzf is loaded from its hook instead
  programs.fzf.enableZshIntegration = false;

  home.packages = [ switch-review ];

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    shellAliases = {
      ll = "ls -l";
      # Review what changed since the running system (never blocks), then
      # build and ask before switching this host from ~/.nix-config.
      update = "${switch-review}/bin/switch-review; nh os switch --ask";
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
