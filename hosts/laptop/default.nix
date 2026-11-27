{ inputs, ... }:

{
  imports = [
    inputs.hardware.nixosModules.lenovo-thinkpad-t480
    ./hardware-configuration.nix
    ../_shared/global.nix
    ../_shared/components/workstation.nix
    # Device is only used when formatting; check `lsblk` on the laptop first.
    (import ../_shared/components/impermanence/disko.nix {
      device = "/dev/nvme0n1";
      swapSize = "16G";
      cacheSubvolume = true;
    })
  ];

  networking.hostName = "laptop";

  # Intel thermal management: less throttling, quieter fans. Runs next to
  # nixos-hardware's throttled: its README says thermald "can conflict" but not
  # to disable it blindly; measure both setups on the T480 before dropping one.
  services.thermald.enable = true;

  # First-install release, never raised afterwards (docs/impermanence.md).
  system.stateVersion = "26.11";
}
