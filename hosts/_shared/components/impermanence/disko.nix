# Disk layout for impermanent hosts: ESP + btrfs (optionally inside LUKS).
# Only used for formatting at install time; afterwards it just provides the
# matching `fileSystems`/`swapDevices`/LUKS config (by partlabel, not device).
#
# Usage: (import ../_shared/components/impermanence/disko.nix { device = "/dev/nvme0n1"; swapSize = "32G"; })
#   encrypt = false   plain btrfs (cloud VMs, see docs/cloud.md)
#   biosBoot = true   extra BIOS boot partition for GRUB on legacy-BIOS VMs (Hetzner Cloud)
#   cacheSubvolume = true   ~/.cache on its own subvolume, outside the /home snapshots
{
  device,
  swapSize, # whole GiB, e.g. "16G"
  encrypt ? true,
  biosBoot ? false,
  cacheSubvolume ? false,
}:
{
  inputs,
  lib,
  config,
  ...
}:
let
  names = import ./names.nix;
  mountOptions = [
    "compress=zstd"
    "noatime"
  ];
  btrfs = {
    type = "btrfs";
    extraArgs = [ "-f" ];
    subvolumes = {
      # Wiped on every boot, see ./default.nix
      "/root" = {
        mountpoint = "/";
        inherit mountOptions;
      };
      "/persist" = {
        mountpoint = "/persist";
        inherit mountOptions;
      };
      "/home" = {
        mountpoint = "/home";
        inherit mountOptions;
      };
      # btrbk snapshots of /home, see ./default.nix
      "/snapshots" = {
        mountpoint = "/.snapshots";
        inherit mountOptions;
      };
      "/nix" = {
        mountpoint = "/nix";
        inherit mountOptions;
      };
      "/swap" = {
        mountpoint = "/swap";
        swap.swapfile.size = swapSize;
      };
    }
    // lib.optionalAttrs cacheSubvolume {
      # ~/.cache on its own subvolume: caches (browsers, JetBrains, npm, NuGet,
      # ...) churn a lot and can always be rebuilt, so they must not end up in
      # the /home snapshots (a subvolume mounted inside /home is not part of
      # the snapshot of /home). Kept across reboots like /home itself.
      "/cache" = {
        mountpoint = "/home/${config.host.user}/.cache";
        inherit mountOptions;
      };
    };
  };
in
{
  imports = [ inputs.disko.nixosModules.disko ];

  # A fresh subvolume belongs to root. The mount is part of local-fs, so this
  # runs after it, and the change stays on the disk.
  systemd.tmpfiles.rules = lib.optional cacheSubvolume "d /home/${config.host.user}/.cache 0700 ${config.host.user} users -";

  disko.devices.disk.main = {
    type = "disk";
    inherit device;
    # Only for `vmWithDisko` test images: room for the swapfile plus the system.
    imageSize = "${toString (lib.toInt (lib.removeSuffix "G" swapSize) + 16)}G";
    content = {
      type = "gpt";
      partitions =
        lib.optionalAttrs biosBoot {
          boot = {
            size = "1M";
            type = "EF02";
            priority = 1;
          };
        }
        // {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [
                "fmask=0077"
                "dmask=0077"
              ];
            };
          };
        }
        // (
          if encrypt then
            {
              luks = {
                size = "100%";
                content = {
                  type = "luks";
                  name = names.luks;
                  settings.allowDiscards = true;
                  content = btrfs;
                };
              };
            }
          else
            {
              root = {
                size = "100%";
                content = btrfs;
              };
            }
        );
    };
  };
}
