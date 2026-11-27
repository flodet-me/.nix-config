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

  # winvm's data stays in the old checkout on the data disk (not snapshotted;
  # ADR 0006). A file, not a session variable: every shell and GNOME app (Rider,
  # MSBuild's `winvm deploy`) sees it at once, without a new login.
  xdg.configFile."winvm/home".text = "${config.home.homeDirectory}/Projects/windows-vm\n";

  # First-install release, never raised afterwards (docs/impermanence.md).
  home.stateVersion = "26.11";
}
