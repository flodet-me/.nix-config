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
    ../_shared/components/workstation.nix
    (import ../_shared/components/impermanence/disko.nix {
      device = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNF0R540542W";
      swapSize = "32G";
      cacheSubvolume = true;
    })
    # Samsung 860 EVO 1 TB (SATA), erased on every install: games, projects and
    # their build output, all re-creatable bulk that stays out of the /home
    # snapshots. steam: the Steam library (add /data/steam once in Steam:
    # Settings > Storage). ~/Projects and ~/Games are bind-mounted from here.
    (import ../_shared/components/data-disk.nix {
      disk = "/dev/disk/by-id/ata-Samsung_SSD_860_EVO_1TB_S3Z9NBRK603979F";
      directories = [ "steam" ];
      homeBinds = {
        Projects = "projects";
        Games = "games";
      };
    })
    ../_shared/components/nvidia-graphics-driver.nix
    ../_shared/components/nvidia-cuda.nix
    ../_shared/components/gaming.nix
  ];

  networking.hostName = "desktop";

  programs.xwayland.enable = true; # Xwayland on PATH for X11 apps (Steam, Wine, ...)

  hardware.nvidia.powerLimit = 150; # watts, quieter and cooler for little speed

  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true; # powers up the default Bluetooth controller on boot
  services.blueman.enable = true;

  programs.streamcontroller.enable = true;
  fonts.fontDir.enable = true;

  environment.systemPackages = with pkgs; [
    android-studio
    stremio-linux-shell
  ];

  # qemu-vm replaces videoDrivers, hiding the nvidia driver (VM tests only)
  virtualisation.vmVariantWithDisko.hardware.nvidia-container-toolkit.suppressNvidiaDriverAssertion =
    true;

  # First-install release, never raised afterwards (docs/impermanence.md).
  system.stateVersion = "26.11";
}
