{
  config,
  pkgs,
  ...
}:

{
  imports = [
    ../_shared/global.nix
    ../_shared/desktop.nix
  ];

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    libreoffice-qt
  ];

  # Lutris and Heroic install into ~/Games by default: keep the games on the
  # data disk, out of /home and its snapshots (hosts/desktop/default.nix). A
  # dangling link while the disk is absent is harmless.
  home.file."Games".source = config.lib.file.mkOutOfStoreSymlink "/data/games";

  # First-install release, never raised afterwards (docs/impermanence.md).
  home.stateVersion = "26.11";
}
