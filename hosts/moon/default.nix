{
  config,
  inputs,
  pkgs,
  ...
}:

{
  imports = [
    inputs.hardware.nixosModules.common-cpu-intel
    inputs.hardware.nixosModules.common-pc-ssd

    ./hardware-configuration.nix
    ../_shared/global.nix
  ];

  programs.zsh.enable = true;

  networking.hostName = "moon"; # Define your hostname.

  # Enable networking
  networking.networkmanager.enable = true;

  services.openssh.enable = true;


  environment.pathsToLink = [ "/share/zsh-vi-mode" ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11";
}
