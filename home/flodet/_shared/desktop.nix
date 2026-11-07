{
  inputs,
  pkgs,
  ...
}:
{
  imports = [
    ./components/firefox.nix
    ./components/vscode.nix
    ./assets
  ];

  # rofi is not used; the stylix target still sets the renamed
  # programs.rofi.font (evaluation warning)
  stylix.targets.rofi.enable = false;

  home.packages = with pkgs; [
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
