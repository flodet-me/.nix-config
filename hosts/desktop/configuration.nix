{
  config,
  inputs,
  pkgs,
  ...
}:

{
  imports = [
    inputs.hardware.nixosModules.common-cpu-amd
    inputs.hardware.nixosModules.common-gpu-amd
    inputs.hardware.nixosModules.common-pc-ssd

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

  programs.hyprland = {
    enable = true;
    # set the flake package
    package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    # make sure to also set the portal package, so that they are in sync
    portalPackage =
      inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  programs.streamcontroller.enable = true;
  programs.zsh.enable = true;

  networking.hostName = "desktop"; # Define your hostname.

  fonts.fontDir.enable = true;

  # Enable networking
  networking.networkmanager.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  services.mullvad-vpn = {
    enable = true;
    package = pkgs.mullvad-vpn;
  };

  # Install firefox.
  programs.firefox.enable = true;

  virtualisation.docker = {
    enable = true;
  };

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
    zotero
    nextcloud-client
    tenacity
    alsa-utils
    easyeffects

    # voip
    discord

    # browser
    chromium

    # encryption
    veracrypt

    jetbrains.rider
    kitty
  ];

  environment.pathsToLink = [ "/share/zsh-vi-mode" ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11";
}
