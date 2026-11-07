{
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
    drawio
  ];

  # First-install release, never raised afterwards (docs/impermanence.md).
  home.stateVersion = "26.11";
}
