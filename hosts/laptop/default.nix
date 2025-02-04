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
    ../_shared/components/silentboot.nix
    ../_shared/components/nvidia-graphics-driver.nix
    ../_shared/components/nvidia-cuda.nix
    ../_shared/components/pipewire.nix
    ../_shared/components/wireshark.nix
    ../_shared/components/gnome.nix
    ../_shared/components/cli-defaults.nix
    ../_shared/components/gaming.nix
    ../_shared/components/vpn-fernuni-hagen.nix
  ];

  hardware.keyboard.qmk.enable = true;
  services.udev.packages = [
    pkgs.headsetcontrol
    pkgs.vial
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.luks.devices."luks-d097a819-f605-4012-9aa0-88c17e095ed0".device =
    "/dev/disk/by-uuid/d097a819-f605-4012-9aa0-88c17e095ed0";


  networking.hostName = "laptop"; # Define your hostname.

  # Enable networking
  networking.networkmanager.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  services.mullvad-vpn = {
    enable = true;
    package = pkgs.mullvad-vpn;
  };

  virtualisation.docker = {
    enable = true;
  };

  virtualisation.libvirtd.enable = true;
  programs.virt-manager.enable = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    spotify
    vlc
    gimp
    obs-studio
    blender
    krita
    kdenlive
    imagemagick
    headsetcontrol
    vial
    pandoc

    jdk23
    nodejs

    # voip
    discord

    # browser
    chromium

    # encryption
    veracrypt
  ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11";
}
