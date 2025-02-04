{
  config,
  pkgs,
  ...
}:

{
  imports = [
    ../_shared/global.nix
    ../_shared/desktop.nix
    ../_shared/desktop-environments/hyprland
    ../_shared/components/qmk
    ../_shared/components/easyeffects
    ../_shared/desktop-environments/gnome
    ../_shared/secrets
  ];

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
