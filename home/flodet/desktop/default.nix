{
  config,
  pkgs,
  inputs,
  ...
}:

{
  home.username = "flodet";
  home.homeDirectory = "/home/flodet";

  nix.package = pkgs.nix;
  programs.vscode = {
    enable = true;
    package = pkgs.vscodium;
    extensions = with pkgs.vscode-extensions; [
      vscodevim.vim
      jnoortheen.nix-ide
      mkhl.direnv
      arrterian.nix-env-selector
      ms-azuretools.vscode-docker
      editorconfig.editorconfig
      ms-python.python
      github.copilot
      github.copilot-chat
      esbenp.prettier-vscode
      streetsidesoftware.code-spell-checker
      sonarsource.sonarlint-vscode
      mhutchie.git-graph
      waderyan.gitblame
      bierner.markdown-mermaid
      bierner.markdown-preview-github-styles
      bierner.markdown-emoji
      bierner.markdown-checkbox
      bierner.markdown-footnotes

      timonwong.shellcheck
      mads-hartmann.bash-ide-vscode
    ];
    userSettings = {
      "workbench.sideBar.location" = "right";
      "editor.renderWhitespace" = "all";
      "editor.inlineSuggest.syntaxHighlightingEnabled" = true;
      "files.autoSave" = "afterDelay";
      "files.autoSaveWhenNoErrors" = true;
      "accessibility.dimUnfocused.enabled" = false;
      "explorer.fileNesting.enabled" = true;
      "vim.enableNeovim" = true;
      "vim.highlightedyank.enable" = true;
      "vim.useSystemClipboard" = true;
      "vim.useCtrlKeys" = false;
    };
  };

  programs.tmux = {
    enable = true;
    plugins = with pkgs; [
      tmuxPlugins.better-mouse-mode
    ];
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    initExtra = ''
      if command -v tmux &> /dev/null && [ -z "$TMUX" ]; then
        tmux
      fi
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

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    # jetbrains.rider

    # Gnome
    gnome-tweaks
    gnomeExtensions.headsetcontrol
    gnomeExtensions.clipboard-history
    gnomeExtensions.alphabetical-app-grid
    gnomeExtensions.mullvad-indicator
    gnomeExtensions.dock-from-dash
    gnomeExtensions.space-bar
    gnomeExtensions.emoji-copy
    gnomeExtensions.color-picker

    cameractrls
    cameractrls-gtk3
    stremio
    drawio

    lunarvim
    nerd-fonts.fira-code
  ];

  fonts.fontconfig.enable = true;

  programs.git = {
    enable = true;
    lfs = {
      enable = true;
    };
    includes = [
      {
        path = ./gitconfig;
      }
    ];
  };

  programs.bash = {
    enable = true;
    enableCompletion = true;

    # set some aliases, feel free to add more or remove some
    shellAliases = {
      k = "kubectl";
      urldecode = "python3 -c 'import sys, urllib.parse as ul; print(ul.unquote_plus(sys.stdin.read()))'";
      urlencode = "python3 -c 'import sys, urllib.parse as ul; print(ul.quote_plus(sys.stdin.read()))'";
    };
  };

  imports = [
    ../../../config/easyeffects/default.nix
    ../../../config/qmk/default.nix
    ../../../config/stream-controller/default.nix
    ../../../modules/home-manager/stylix/stylix.nix
  ];

  # ...
  dconf.settings = {

    # ...
    "org/gnome/shell" = {
      disable-user-extensions = false;

      # `gnome-extensions list` for a list

      enabled-extensions = [
        "AlphabeticalAppGrid@stuarthayhurst"
        "clipboard-history@alexsaveau.dev"
        "dock-from-dash@fthx"
        "mullvadindicator@pobega.github.com"
        "HeadsetControl@lauinger-clan.de"
        "emoji-copy@felipeftn"
        "system-monitor@gnome-shell-extensions.gcampax.github.com"
        "user-theme@gnome-shell-extensions.gcampax.github.com"
        "space-bar@luchrioh"
        "color-picker@tuberry"
      ];

      favorite-apps = [
        "firefox.desktop"
        "org.gnome.Console.desktop"
        "org.gnome.Nautilus.desktop"
      ];
    };

    "org/gnome/desktop/interface" = {
      # color-scheme = "prefer-dark";
      enable-hot-corners = false;
      clock-format = "24h";
      accent-color = "blue";

      # Set middle click paste
      gtk-enable-primary-paste = true;
    };

    "org/gnome/desktop/datetime" = {
      automatic-timezone = true;
    };

    "org/gnome/desktop/wm/preferences" = {
      workspace-names = [ "Main" ];
      button-layout = "appmenu:minimize,maximize,close";
    };
  };
  # This value determines the home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update home Manager without changing this value. See
  # the home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "24.11";

  # Let home Manager install and manage itself.
  programs.home-manager.enable = true;
}
