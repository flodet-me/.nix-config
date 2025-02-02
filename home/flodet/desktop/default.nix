{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:

{
  imports = [
    ./hyprland
    ../_shared/global.nix
    ../_shared/desktop.nix
    ../_shared/desktop-environments/hyprland
    ../_shared/components/qmk
    ../_shared/components/stream-controller
    ../_shared/components/easyeffects
    ../_shared/desktop-environments/gnome
    ../_shared/secrets
  ];

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    cameractrls
    cameractrls-gtk3
    stremio
    drawio
  ];

  fonts.fontconfig.enable = true;

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
