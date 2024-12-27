{ config, pkgs, ... }:

{
  # TODO please change the username & home directory to your own
  home.username = "flodet";
  home.homeDirectory = "/home/flodet";

  # encode the file content in nix configuration file directly
  # home.file.".xxx".text = ''
  #     xxx
  # '';

  programs.vscode = {
    enable = true;
    package = pkgs.vscodium;
    extensions = with pkgs.vscode-extensions; [
      vscodevim.vim
      jnoortheen.nix-ide

    ];
  };

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    # here is some command line tools I use frequently
    # feel free to add your own or remove some of them

    neofetch
    vial

    # archives
    zip
    xz
    unzip
    p7zip

    # utils
    ripgrep # recursively searches directories for a regex pattern
    jq # A lightweight and flexible command-line JSON processor
    yq-go # yaml processor https://github.com/mikefarah/yq
    eza # A modern replacement for ‘ls’
    fzf # A command-line fuzzy finder

    # networking tools
    mtr # A network diagnostic tool
    iperf3
    dnsutils # `dig` + `nslookup`
    ldns # replacement of `dig`, it provide the command `drill`
    aria2 # A lightweight multi-protocol & multi-source command-line download utility
    socat # replacement of openbsd-netcat
    nmap # A utility for network discovery and security auditing
    ipcalc # it is a calculator for the IPv4/v6 addresses

    # misc
    cowsay
    file
    which
    tree
    gnused
    gnutar
    gawk
    zstd
    gnupg

    # nix related
    #
    # it provides the command `nom` works just like `nix`
    # with more details log output
    nix-output-monitor

    # productivity
    glow # markdown previewer in terminal

    btop # replacement of htop/nmon
    iotop # io monitoring
    iftop # network monitoring

    # system call monitoring
    strace # system call monitoring
    ltrace # library call monitoring
    lsof # list open files

    # system tools
    sysstat
    lm_sensors # for `sensors` command
    ethtool
    pciutils # lspci
    usbutils # lsusb

    # Gnome
    gnome-tweaks
    gnomeExtensions.headsetcontrol
    gnomeExtensions.clipboard-history
    gnomeExtensions.alphabetical-app-grid
    gnomeExtensions.mullvad-indicator
    gnomeExtensions.dock-from-dash
    gnomeExtensions.space-bar
    headsetcontrol
    gnomeExtensions.emoji-copy

    cameractrls
    cameractrls-gtk3

    dconf-editor
  ];

  # basic configuration of git, please change to your own
  programs.git = {
    enable = true;
    userName = "Flodet";
    userEmail = "develop@flodet.me";
  };

  programs.bash = {
    enable = true;
    enableCompletion = true;
    # TODO add your custom bashrc here
    bashrcExtra = ''
      export PATH="$PATH:$HOME/bin:$HOME/.local/bin:$HOME/go/bin"
    '';

    # set some aliases, feel free to add more or remove some
    shellAliases = {
      k = "kubectl";
      urldecode = "python3 -c 'import sys, urllib.parse as ul; print(ul.unquote_plus(sys.stdin.read()))'";
      urlencode = "python3 -c 'import sys, urllib.parse as ul; print(ul.quote_plus(sys.stdin.read()))'";
    };
  };

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
      ];

      favorite-apps = [
        "firefox.desktop"
        "org.gnome.Terminal.desktop"
        "org.gnome.Nautilus.desktop"
      ];
    };

    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
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
