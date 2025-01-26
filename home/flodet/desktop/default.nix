{
  config,
  pkgs,
  inputs,
  ...
}:

{
  imports = [
    ../_shared/global.nix
    ../_shared/components/vscode.nix
    ../_shared/components/stylix
    ../_shared/components/qmk
    ../_shared/components/stream-controller
    ../_shared/components/easyeffects
    inputs.sops-nix.homeManagerModules.sops
  ];

  home.username = "flodet";
  home.homeDirectory = "/home/flodet";

  home.sessionVariables = {
    mail = config.sops.secrets.openai_api_key.path;
  };

  sops = {
    age.keyFile = "/home/flodet/.config/sops/age/keys.txt"; # must have no password!
    # It's also possible to use a ssh key, but only when it has no password:
    #age.sshKeyPaths = [ "/home/user/path-to-ssh-key" ];
    defaultSopsFile = ./secrets.yaml;
    defaultSymlinkPath = "/run/user/1000/secrets";
    defaultSecretsMountPoint = "/run/user/1000/secrets.d";

    secrets.git_mail = {
      # sopsFile = ./secrets.yml.enc; # optionally define per-secret files

      # %r gets replaced with a runtime directory, use %% to specify a '%'
      # sign. Runtime dir is $XDG_RUNTIME_DIR on linux and $(getconf
      # DARWIN_USER_TEMP_DIR) on darwin.
      path = "${config.sops.defaultSymlinkPath}/git_mail";
    };
  };

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
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
}
