{ config, pkgs, ... }:
let
  # Caches that default to a dot-directory of their own. ~/.cache is its own
  # subvolume (impermanence/disko.nix, cacheSubvolume), outside the /home
  # snapshots, so everything that is only a cache belongs inside it. Set for
  # shells and, through the systemd user environment, for GNOME apps (Rider).
  cacheVariables = {
    NUGET_PACKAGES = "${config.xdg.cacheHome}/nuget"; # dotnet packages, re-downloadable
    NPM_CONFIG_CACHE = "${config.xdg.cacheHome}/npm";
  };
in
{
  imports = [
    ./components/firefox.nix
    ./components/vscode.nix
    ./components/qmk
    ./components/yubikey-gpg.nix
    ./components/claude-code
    ./components/stream-controller
    ./components/easyeffects
    ./desktop-environments/gnome
  ];

  home.sessionVariables = cacheVariables;
  systemd.user.sessionVariables = cacheVariables;

  fonts.fontconfig.enable = true;

  # rofi is not used; the stylix target still sets the renamed
  # programs.rofi.font (evaluation warning)
  stylix.targets.rofi.enable = false;

  home.packages = with pkgs; [
    cameractrls
    cameractrls-gtk3
    spotify
    vlc
    gimp
    obs-studio
    blender
    krita
    kdePackages.kdenlive
    imagemagick
    headsetcontrol
    vial
    pandoc

    nextcloud-client
    tenacity
    alsa-utils
    calibre

    ledger-live-desktop
    obsidian
    # voip
    discord

    # browser
    chromium

    # encryption
    veracrypt

    jetbrains.rider

    # API client (HTTP, gRPC); collections are plain files that go in git
    bruno
  ];
}
