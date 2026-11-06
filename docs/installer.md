# Installer stick

An offline NixOS installer for `desktop` and `laptop`. It contains this repo,
all flake inputs and both systems' complete closures, so installing needs no
network. Config: `hosts/installer/`.

## Build, try, write (dev shell)

```sh
installer-vm                  # optional: try it in a QEMU window first (blank NVMe disk)
installer-vm --boot           #   ... and boot what was installed there
make-installer-stick          # build the ISO (~16 GB) and write + verify it
```

`make-installer-stick` only accepts removable USB disks, unmounts them, asks
you to type the device name, writes with `dd` (sudo) and reads it back to
verify. `--iso FILE` skips the build, a device argument skips the selection.
The ISO alone: `nix build .#installer-iso`.

Rebuild the image after changing the config so the stick installs the current
state (it installs what was baked in, not what is on GitHub).

## Install

1. Back up `/home/flodet` if the machine had data.
2. Boot the stick (UEFI), you are logged in as `nixos`.
3. Optional: network via `nmtui` (not needed for installing).
4. Plug in the YubiKey and run:
   ```sh
   sudo install-host laptop            # or: desktop
   sudo install-host laptop --disk /dev/nvme0n1   # if the configured disk differs
   ```
   It shows the target disk and asks for the host name before erasing it, then:
   - formats it (LUKS2 + btrfs, asks for the new disk passphrase),
   - generates the host's sops key in `/persist/var/lib/sops-nix/key.txt`,
   - registers it in `.sops.yaml` and re-encrypts the secrets with the
     YubiKey (asks for the PIN), then checks the new key can decrypt them,
   - optionally pauses so you can restore data into `/mnt` (e.g.
     `rsync -aHAX /path/to/backup/home/ /mnt/home/`),
   - runs `nixos-install`.
5. Reboot, remove the stick.
6. The changed `.sops.yaml` and secrets files are saved in
   `~/sops-registration-<host>-<date>/`. Copy them into the repo, commit,
   push. (If `~/.nix-config` didn't exist, the installer's copy is placed
   there, without git history: `git clone` the repo instead and copy the files.)

Without the YubiKey the install still works, but secrets (Mullvad login,
hyprland keys, ...) stay missing until the printed public key is registered
from another machine (`sops-register-host <host> <pubkey>`, `docs/secrets.md`)
and the host is rebuilt.

## Notes

- Reinstalling a host replaces its key in `.sops.yaml`; the old key can no
  longer decrypt new versions of the secrets.
- The installer writes the target disk into its working copy when `--disk`
  is given, so commit that change too if the disk really differs.
