{
  config,
  inputs,
  pkgs,
  ...
}:

{
  imports = [
    inputs.hardware.nixosModules.lenovo-thinkpad-t480
    inputs.hardware.nixosModules.common-laptop-ssd
    inputs.hardware.nixosModules.common-cpu-intel-kaby-lake

    ./hardware-configuration.nix
    ./users.nix
    ../../modules/gnome.nix
    ../../modules/boot.nix
    ../../modules/cli-defaults.nix
    ../../modules/stylix/stylix.nix
    ../../modules/culture.nix
  ];

  hardware.keyboard.qmk.enable = true;
  services.udev.packages = [
    pkgs.headsetcontrol
    pkgs.vial
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  programs.zsh.enable = true;

  networking.hostName = "laptop"; # Define your hostname.

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 1w";
  };

  # Enable networking
  networking.networkmanager.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  services.mullvad-vpn = {
    enable = true;
    package = pkgs.mullvad-vpn;
  };

  # Install firefox.
  programs.firefox.enable = true;

  virtualisation.docker = {
    enable = true;
  };

  virtualisation.virtualbox.host = {
    enable = true;
    enableExtensionPack = true;
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

    # voip
    discord

    # browser
    chromium

    # encryption
    veracrypt
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
