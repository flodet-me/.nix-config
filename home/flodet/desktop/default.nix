{
  config,
  pkgs,
  ...
}:
let
  winvmHome = "${config.home.homeDirectory}/Projects/windows-vm";
in
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
  # ADR 0006). The systemd user environment carries it to GNOME apps, so Rider
  # and MSBuild's `winvm deploy` find the same VMs.
  home.sessionVariables.WINVM_HOME = winvmHome;
  systemd.user.sessionVariables.WINVM_HOME = winvmHome;

  # First-install release, never raised afterwards (docs/impermanence.md).
  home.stateVersion = "26.11";
}
