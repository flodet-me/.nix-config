# "Erase your darlings": the root subvolume is replaced with an empty one on
# every boot. Only /nix, /home, /persist (and what is bind-mounted from it
# below) survive. Requires the btrfs layout from ./disko.nix.
#
# Run `fs-diff` to list what currently lives on the ephemeral root, i.e. what
# would be lost on the next reboot. Previous roots are kept for
# `impermanence.oldRootRetentionDays` days in the btrfs top level under
# /old_roots in case something was missed (that includes /tmp and /root, so
# big temporary files live on until then).
{
  config,
  lib,
  pkgs,
  inputs,
  utils,
  ...
}:
let
  names = import ./names.nix;
  # The btrfs device holding all subvolumes (LUKS mapper or plain partition)
  rootDevice = config.fileSystems."/".device;
  rootDeviceUnit = "${utils.escapeSystemdPath rootDevice}.device";
  gnome = config.services.desktopManager.gnome.enable;

  # With persistVarLib, all of /var/lib replaces the individual entries below.
  varLib =
    dirs:
    if config.impermanence.persistVarLib then
      [ "/var/lib" ] ++ lib.filter (dir: !lib.hasPrefix "/var/lib/" dir) dirs
    else
      dirs;
in
{
  imports = [ inputs.impermanence.nixosModules.impermanence ];

  # Servers: any enabled service keeps its state (and is backed up, see
  # server/backup.nix) without listing it here.
  options.impermanence.persistVarLib = lib.mkEnableOption "persisting all of /var/lib instead of a curated list";

  options.impermanence.oldRootRetentionDays = lib.mkOption {
    type = lib.types.ints.positive;
    default = 30;
    description = "How many days wiped root subvolumes are kept under /old_roots.";
  };

  options.impermanence.sendSnapshotsTo = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "ssh://moon/mnt/backup/laptop";
    description = "btrbk target (a mounted path or ssh://host/path) that /home snapshots are sent to with btrfs send/receive. Off by default; fails (and logs) while the target is unavailable.";
  };

  config = {

    # Read directly from /persist: secrets are decrypted during activation,
    # before impermanence's bind mounts exist.
    sops.age.keyFile = names.sopsAgeKey;

    # /home too: user creation runs during activation, before regular
    # filesystems are mounted.
    fileSystems."/persist".neededForBoot = true;
    fileSystems."/home".neededForBoot = true;
    # `vmWithDisko` replaces fileSystems with its own definitions.
    virtualisation.vmVariantWithDisko.virtualisation.fileSystems = {
      "/persist".neededForBoot = true;
      "/home".neededForBoot = true;
    };

    # /home is the only place personal data lives, so keep cheap snapshots of
    # it (in /.snapshots). Deleted files only free space once snapshots expire.
    services.btrbk.instances.home = {
      onCalendar = "hourly";
      settings = {
        snapshot_preserve_min = "2d";
        snapshot_preserve = "48h 14d 4w";
        volume."/" = {
          subvolume = "home";
          snapshot_dir = ".snapshots";
        }
        // lib.optionalAttrs (config.impermanence.sendSnapshotsTo != null) {
          target = config.impermanence.sendSnapshotsTo;
          target_preserve_min = "2d";
          target_preserve = "14d 8w 12m";
        };
      };
    };

    services.btrfs.autoScrub = {
      enable = true;
      interval = "monthly";
      fileSystems = [ "/" ];
    };

    boot.initrd.systemd.services.rollback = {
      description = "Replace btrfs root subvolume with an empty one";
      wantedBy = [ "initrd.target" ];
      requires = [ rootDeviceUnit ];
      after = [
        rootDeviceUnit
      ]
      ++ lib.optional (
        config.boot.initrd.luks.devices ? ${names.luks}
      ) "systemd-cryptsetup@${names.luks}.service";
      before = [ "sysroot.mount" ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p /btrfs_tmp
        mount -t btrfs -o subvol=/ ${rootDevice} /btrfs_tmp

        delete_subvolume_recursively() {
          IFS=$'\n'
          for i in $(btrfs subvolume list -o "$1" | cut -f 9- -d ' '); do
            delete_subvolume_recursively "/btrfs_tmp/$i"
          done
          btrfs subvolume delete "$1"
        }

        if [[ -e /btrfs_tmp/root ]]; then
          mkdir -p /btrfs_tmp/old_roots
          timestamp=$(date --date="@$(stat -c %Y /btrfs_tmp/root)" "+%Y-%m-%d_%H:%M:%S")
          # -$$ keeps two roots of the same second apart (mv would nest otherwise)
          mv /btrfs_tmp/root "/btrfs_tmp/old_roots/$timestamp-$$"
        fi

        # The new root comes first: nothing below may keep the system from booting
        btrfs subvolume create /btrfs_tmp/root

        cutoff=$(( $(date +%s) - ${toString config.impermanence.oldRootRetentionDays} * 24 * 60 * 60 ))
        for old in /btrfs_tmp/old_roots/*; do
          [[ -e "$old" ]] || continue
          if (( $(stat -c %Y "$old") < cutoff )); then
            delete_subvolume_recursively "$old" || echo "could not delete $old" >&2
          fi
        done
        umount /btrfs_tmp
      '';
    };

    environment.persistence."/persist" = {
      hideMounts = true;
      directories = varLib (
        [
          "/var/log"
          "/var/lib/nixos" # uid/gid allocations
          "/var/lib/systemd" # timers, random seed, backlight, coredumps
          "/var/db/sudo/lectured"
        ]
        ++ lib.optionals config.networking.networkmanager.enable [
          "/etc/NetworkManager/system-connections"
          "/var/lib/NetworkManager"
        ]
        ++ lib.optionals gnome [
          "/var/lib/AccountsService"
          "/var/lib/colord"
          "/var/lib/upower"
          "/var/lib/power-profiles-daemon"
          "/var/lib/boltd"
        ]
        ++ lib.optional config.hardware.bluetooth.enable "/var/lib/bluetooth"
        ++ lib.optional config.services.fwupd.enable "/var/lib/fwupd"
        ++ lib.optional config.services.printing.enable "/var/lib/cups"
        ++ lib.optional config.virtualisation.docker.enable "/var/lib/docker"
        ++ lib.optional config.virtualisation.podman.enable "/var/lib/containers"
        ++ lib.optional config.virtualisation.libvirtd.enable "/var/lib/libvirt"
        ++ lib.optionals config.services.mullvad-vpn.enable [
          "/etc/mullvad-vpn"
          "/var/cache/mullvad-vpn"
        ]
        # server services
        ++ lib.optional config.security.acme.acceptTerms "/var/lib/acme"
        ++ lib.optional config.services.caddy.enable "/var/lib/caddy"
        ++ lib.optional config.services.postgresql.enable "/var/lib/postgresql"
        ++ lib.optional config.services.fail2ban.enable "/var/lib/fail2ban"
      );
      files = [
        "/etc/machine-id"
      ];
    };

    # SSH host keys straight from /persist (no bind mount needed at sshd start).
    # Only ed25519: modern, and what known_hosts pins (docs/cloud.md).
    services.openssh.hostKeys = [
      {
        path = "/persist/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];

    # Defaults for `nix run .#nixosConfigurations.<host>.config.system.build.vmWithDisko`
    virtualisation.vmVariantWithDisko.virtualisation = {
      memorySize = 4096;
      cores = 4;
    };

    environment.systemPackages = [
      (pkgs.writeShellApplication {
        name = "fs-diff";
        text = ''
          # Everything on the ephemeral root (other subvolumes and bind mounts
          # are separate devices, so -xdev skips them). NixOS's own /etc symlinks
          # (into /etc/static) are regenerated on every boot, so not listed.
          sudo find / -xdev \
            \( -path /tmp -o -path /var/tmp \) -prune -o \
            \( -type f -o -type l \) \
            ! -lname '/etc/static/*' ! -path /etc/machine-id -print | sort| sort
        '';
      })
    ];
  };
}
