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
    ../_shared/users/flodet/workstation.nix
    (import ../_shared/components/impermanence/disko.nix {
      device = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNF0R540542W";
      swapSize = "32G";
    })
    ../_shared/components/impermanence
    ../_shared/components/silentboot.nix
    ../_shared/components/nvidia-graphics-driver.nix
    ../_shared/components/nvidia-cuda.nix
    ../_shared/components/pipewire.nix
    ../_shared/components/wireshark.nix
    ../_shared/components/gnome.nix
    ../_shared/components/cli-defaults.nix
    ../_shared/components/yubikey-gpg.nix
    ../_shared/components/firmware-updates.nix
    ../_shared/components/workstation-health.nix
    ../_shared/components/libvirt.nix
    ../_shared/components/claude-code.nix
    ../_shared/components/gaming.nix
    ../_shared/components/vpn-fernuni-hagen.nix
    ../_shared/components/mullvad-vpn.nix
    ../_shared/components/server-access.nix
    ../_shared/components/stylix.nix
  ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;

  boot.loader.efi.canTouchEfiVariables = true;

  # qemu-vm replaces videoDrivers, hiding the nvidia driver (VM tests only)
  virtualisation.vmVariantWithDisko.hardware.nvidia-container-toolkit.suppressNvidiaDriverAssertion =
    true;

  hardware.keyboard.qmk.enable = true;
  services.udev.packages = [
    pkgs.headsetcontrol
    pkgs.vial
  ];

  programs.dconf.enable = true;

  hardware.bluetooth.enable = true; # enables support for Bluetooth
  hardware.bluetooth.powerOnBoot = true; # powers up the default Bluetooth controller on boot
  services.blueman.enable = true;

  programs.xwayland.enable = true;

  programs.streamcontroller.enable = true;
  programs.zsh.enable = true;

  networking.hostName = "desktop"; # Define your hostname.

  fonts.fontDir.enable = true;

  # Enable networking
  networking.networkmanager.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  virtualisation.docker = {
    enable = true;
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    android-studio
    stremio-linux-shell
  ];

  systemd.services.nvidia-power-limit = {
    description = "Set NVIDIA GPU Power Limit";
    after = [ "nvidia-persistenced.service" ];
    wants = [ "nvidia-persistenced.service" ];
    wantedBy = [ "multi-user.target" ];

    # We use the driver package already defined in your config
    path = [ config.hardware.nvidia.package ];

    script = ''
      nvidia-smi -pm 1
      nvidia-smi -pl 150
    '';

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  # environment.pathsToLink = [ "/share/zsh-vi-mode" ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "26.11"; # first install of the reinstalled system
}
