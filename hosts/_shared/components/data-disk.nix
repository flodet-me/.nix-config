# A second disk for bulk data (games, projects, VM images): LUKS, then btrfs
# with zstd, mounted at /data and owned by the user. Declared with disko like
# the system disk, so install-host ERASES it together with that one.
#
# Unlocking: install-host makes a random key file, formats the disk with it and
# stores it on the encrypted system disk (/persist/etc/data-disk.key). After
# boot, once the system disk is unlocked, /etc/crypttab opens the data disk
# with that key: one passphrase at boot, and the data is as protected as the
# system disk. Losing the system disk therefore also loses this key: add a
# passphrase as a second way in (docs/installer.md, "Extra data disks").
# `nofail` keeps a missing or locked disk from stopping the boot.
#
# The argument is `disk`, not `device`, so that `install-host --disk` only ever
# changes the system disk.
# `directories` are created below the mount point, owned by the user.
# `homeBinds` maps a path in the user's home to a directory on the disk, which
# is bind-mounted there (and created): { Projects = "projects"; } puts
# ~/Projects on the data disk. A bind mount instead of a symlink, because a
# restored backup that contains a real ~/Projects would make a home-manager
# link fail at activation, while a mount simply covers it. It is `nofail`: with
# the disk absent, ~/Projects is just an empty directory. The /home snapshots do
# not contain what is behind a mount.
# Usage: (import ../_shared/components/data-disk.nix {
#   disk = "/dev/disk/by-id/...";
#   directories = [ "steam" ];
#   homeBinds = { Projects = "projects"; Games = "games"; };
# })
{
  disk,
  mountpoint ? "/data",
  directories ? [ ],
  homeBinds ? { },
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  names = import ./impermanence/names.nix;
  partlabel = "/dev/disk/by-partlabel/disk-data-luks";
  bootOptions = "nofail,x-systemd.device-timeout=10s";
  user = config.host.user;
  allDirectories = lib.unique (directories ++ lib.attrValues homeBinds);
  binds = lib.mapAttrs' (
    name: dir:
    lib.nameValuePair "/home/${user}/${name}" {
      device = "${mountpoint}/${dir}";
      fsType = "none";
      options = [
        "bind"
        "nofail"
        "x-systemd.requires-mounts-for=${mountpoint}"
        # unmount only after login sessions and user managers stopped (they keep it busy)
        "x-systemd.before=systemd-user-sessions.service"
      ];
    }
  ) homeBinds;
in
{
  disko.devices.disk.data = {
    type = "disk";
    device = disk;
    content = {
      type = "gpt";
      partitions.luks = {
        size = "100%";
        content = {
          type = "luks";
          name = names.dataLuks;
          passwordFile = names.dataKeyTmp; # format time only (install-host)
          initrdUnlock = false; # opened after boot by /etc/crypttab below
          settings.allowDiscards = true;
          content = {
            type = "btrfs";
            extraArgs = [ "-f" ];
            inherit mountpoint;
            mountOptions = [
              "compress=zstd"
              "noatime"
              "nofail"
              "x-systemd.device-timeout=10s"
            ];
            # The folders must exist before the first boot mounts them
            postMountHook = lib.concatMapStrings (
              d: "mkdir -p '${config.disko.rootMountPoint}${mountpoint}/${d}'\n"
            ) allDirectories;
          };
        };
      };
    };
  };

  environment.etc.crypttab.text = ''
    ${names.dataLuks} ${partlabel} ${names.dataKey} luks,discard,${bootOptions}
  '';

  fileSystems = binds;

  # The top directory of a fresh filesystem belongs to root. This cannot be a
  # tmpfiles rule: those run early at boot, before this disk is unlocked and
  # mounted, and would only fix the empty directory underneath the mount. The
  # change sticks on the disk, so it matters once; if the disk cannot be
  # mounted (nofail), the service just does not run. It also creates the
  # directories asked for (a no-op when they exist).
  systemd.services.data-disk-owner = {
    description = "Give ${config.host.user} ${mountpoint} and its directories";
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = mountpoint;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = [
        "${pkgs.coreutils}/bin/chown ${config.host.user}:users ${mountpoint}"
      ]
      ++ map (
        d: "${pkgs.coreutils}/bin/install -d -m 0755 -o ${config.host.user} -g users ${mountpoint}/${d}"
      ) allDirectories;
    };
  };

  # `vmWithDisko` (docs: CLAUDE.md) formats with the password "disko" and has no
  # install-host to place a key file: unlock with a key file holding that
  # password. Test only; the key lands in the store.
  virtualisation.vmVariantWithDisko = {
    # the VM replaces `fileSystems` with the disko ones: pass the binds on
    virtualisation.fileSystems = binds;
    disko.devices.disk.data.content.partitions.luks.content.passwordFile = lib.mkForce null;
    environment.etc."data-disk-vm.key" = {
      text = "disko";
      mode = "0400";
    };
    environment.etc.crypttab.text = lib.mkForce ''
      ${names.dataLuks} ${partlabel} /etc/data-disk-vm.key luks,discard,${bootOptions}
    '';
  };
}
