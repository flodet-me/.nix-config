{ config, pkgs, ... }:

{
  services.xserver.enable = true;

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Enable automatic login for the user (the LUKS passphrase/YubiKey at boot is
  # the real gate, see docs/installer.md).
  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = config.host.user;

  # Workaround for GNOME autologin: https://github.com/NixOS/nixpkgs/issues/103746#issuecomment-945091229
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  # Apps replaced by what is already installed (Firefox, VLC, Papers, ...) or
  # not used at all. Everything else of the default GNOME set stays.
  environment.gnome.excludePackages = with pkgs; [
    gnome-tour # the "Welcome to NixOS" popup on first login
    epiphany # web browser
    gnome-music
    decibels # audio player
    showtime # video player
    gnome-contacts
    gnome-maps
    gnome-weather
    gnome-connections # remote desktop client
    simple-scan # no scanner support (hardware.sane is off)
    yelp # help viewer
  ];

  # No network-facing sharing services: RDP/VNC desktop sharing, WebDAV file
  # sharing and the DLNA media server are all on by default.
  services.gnome = {
    gnome-remote-desktop.enable = false;
    gnome-user-share.enable = false;
    rygel.enable = false;
    # File content indexing (background CPU/disk use); only feeds the file
    # results of the shell search and Nautilus search-in-content.
    localsearch.enable = false;
    tinysparql.enable = false;
  };
}
