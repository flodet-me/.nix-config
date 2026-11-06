# Disk layout for impermanent hosts: ESP + btrfs (optionally inside LUKS).
# Only used for formatting at install time; afterwards it just provides the
# matching `fileSystems`/`swapDevices`/LUKS config (by partlabel, not device).
#
# Usage: (import ../_shared/components/impermanence/disko.nix { device = "/dev/nvme0n1"; swapSize = "32G"; })
#   encrypt = false   plain btrfs (cloud VMs, see docs/cloud.md)
#   biosBoot = true   extra BIOS boot partition for GRUB on legacy-BIOS VMs (Hetzner Cloud)
{
  device,
  swapSize,
  encrypt ? true,
  biosBoot ? false,
}:
{ inputs, lib, ... }:
let
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
    };
  };
in
{
  imports = [ inputs.disko.nixosModules.disko ];

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
                  name = "crypted";
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
