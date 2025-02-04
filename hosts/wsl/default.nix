{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ../_shared/global.nix
  ];

  environment.systemPackages = with pkgs; [
    lazydocker
  ];

  # Enable vscode
  # https://nix-community.github.io/NixOS-WSL/how-to/vscode.html
  programs.nix-ld = {
    enable = true;
    package = pkgs.nix-ld-rs; # only for NixOS 24.05
  };

  virtualisation.docker = {
    enable = true;
    enableNvidia = true;
    # Works with the mirrored network mode
    extraOptions = "--host tcp://127.0.0.1:2375";
  };
}
