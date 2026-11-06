{
  config,
  inputs,
  pkgs,
  ...
}:

{
  imports = [
    inputs.hardware.nixosModules.lenovo-thinkpad-t480
    ./hardware-configuration.nix
    ../_shared/global.nix
    ../_shared/users/flodet/workstation.nix
    # Device is only used when formatting; check `lsblk` on the laptop first.
    (import ../_shared/components/impermanence/disko.nix {
      device = "/dev/nvme0n1";
      swapSize = "16G";
    })
    ../_shared/components/impermanence
    ../_shared/components/silentboot.nix
    ../_shared/components/pipewire.nix
    ../_shared/components/wireshark.nix
    ../_shared/components/gnome.nix
    ../_shared/components/yubikey-gpg.nix
    ../_shared/components/firmware-updates.nix
    ../_shared/components/libvirt.nix
    ../_shared/components/claude-code.nix
    ../_shared/components/cli-defaults.nix
    ../_shared/components/vpn-fernuni-hagen.nix
    ../_shared/components/mullvad-vpn.nix
    ../_shared/components/server-access.nix
    ../_shared/components/stylix.nix
  ];

  services.thermald.enable = true; # Intel thermal management: less throttling, quieter fans

  hardware.keyboard.qmk.enable = true;
  services.udev.packages = [
    pkgs.headsetcontrol
    pkgs.vial
  ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;

  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "laptop"; # Define your hostname.

  # Enable networking
  networking.networkmanager.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  virtualisation.docker = {
    enable = true;
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "26.11"; # first install of the reinstalled system
}
