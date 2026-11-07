# Proprietary NVIDIA driver (X11/Wayland), with an optional power limit.
{ config, lib, ... }:
{
  options.hardware.nvidia.powerLimit = lib.mkOption {
    type = lib.types.nullOr lib.types.ints.positive;
    default = null;
    example = 150;
    description = "Power limit of the GPU in watts, applied at boot (nvidia-smi -pl). null: the card's default.";
  };

  config = {
    hardware.graphics.enable = true;
    services.xserver.videoDrivers = [ "nvidia" ];
    # Explicit: modesetting.enable alone no longer puts this on the command line
    boot.kernelParams = [ "nvidia-drm.modeset=1" ];

    hardware.nvidia = {
      modesetting.enable = true; # required
      nvidiaPersistenced = true; # keeps the driver loaded (persistence mode)
      nvidiaSettings = true; # `nvidia-settings`
      package = config.boot.kernelPackages.nvidiaPackages.stable;

      # Saving all VRAM on suspend/hibernate; needed to resume from hibernation.
      # Experimental and can make suspend fail, so off until needed.
      powerManagement.enable = false;
      powerManagement.finegrained = false; # turns the GPU off when idle (laptops, Turing+)

      # Open kernel modules (Turing and newer, driver 515+). The proprietary
      # module is kept: it is what this machine has been tested with.
      open = false;
    };

    systemd.services.nvidia-power-limit = lib.mkIf (config.hardware.nvidia.powerLimit != null) {
      description = "Set the NVIDIA GPU power limit";
      after = [ "nvidia-persistenced.service" ];
      wants = [ "nvidia-persistenced.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ config.hardware.nvidia.package ];
      script = "nvidia-smi -pl ${toString config.hardware.nvidia.powerLimit}";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    };
  };
}
