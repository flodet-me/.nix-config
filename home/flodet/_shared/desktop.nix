{
  pkgs,
  ...
}:
{
  imports = [
    ./components/firefox.nix
    ./components/vscode.nix
    ./components/stylix
    ./components/mullvad-vpn
    ./assets
  ];

  programs.joplin-desktop.enable = true;

  home.packages = with pkgs; [
    spotify
    vlc
    gimp
    obs-studio
    blender
    krita
    kdenlive
    imagemagick
    headsetcontrol
    vial
    pandoc

    zotero
    nextcloud-client
    tenacity
    alsa-utils
    # voip
    discord

    # browser
    chromium

    # encryption
    veracrypt

    jetbrains.rider
  ];
}
