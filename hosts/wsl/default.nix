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

  # https://github.com/nix-community/NixOS-WSL/discussions/487#discussioncomment-11180666
  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      features.cdi = true;
      hosts = [
        "fd://"
        "tcp://127.0.0.1:2375"
      ];
    };
    # Works with the mirrored network mode
  };
  hardware = {
    nvidia = {
      modesetting.enable = true;
      nvidiaSettings = false;
      open = false;
    };
    nvidia-container-toolkit.enable = true;
  };
  services.xserver.videoDrivers = [ "nvidia" ];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
