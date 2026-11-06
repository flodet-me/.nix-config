# Installer stick

An offline NixOS installer for every host with a disko disk layout (currently
`desktop`, `laptop`, `moon`, `vps`). It contains this repo, all flake inputs and the
hosts' complete closures, so installing needs no network. Config:
`installer/`.

## Build, try, write (dev shell)

```sh
installer-vm                  # optional: try it in a QEMU window first (blank NVMe disk)
installer-vm --boot           #   ... and boot what was installed there
make-installer-stick          # build the ISO and write + verify it
```

`make-installer-stick` only accepts removable USB disks, unmounts them, asks
you to type the device name, writes with `dd` (sudo) and reads it back to
verify. `--iso FILE` skips the build, a device argument skips the selection.
The ISO alone: `nix build .#installer-iso`.

The stick installs the config it was built from. Rebuild it after bigger
changes; for secrets it doesn't matter (see "After the install").

## Install

1. Back up `/home/flodet` if the machine had data.
2. Boot the stick (UEFI; on ThinkPads F12, Secure Boot off). You are logged in
   as `nixos`.
3. Plug in the YubiKey and run:
   ```sh
   sudo install-host laptop                       # without argument: lists the hosts on the stick
   sudo install-host laptop --disk /dev/nvme0n1   # if the configured disk differs
   ```
   It shows the target disk and asks for the host name before erasing it, then:
   - formats it (asks for the new disk passphrase),
   - generates the host's sops key in `/persist/var/lib/sops-nix/key.txt`,
   - registers it (`sops-register-host`: `keys/hosts/<host>.age` + `sops-sync`,
     YubiKey PIN) and checks the new key can decrypt the host's secrets,
   - optionally pauses so you can restore data into `/mnt` (e.g.
     `rsync -aHAX /path/to/backup/home/ /mnt/home/`),
   - builds and installs the system, offline.
4. Reboot, remove the stick.

## After the install

Log in (user `flodet`), connect to the network, plug in the YubiKey. The rest
is automatic:

- gpg knows your public key (fully trusted) and learns the YubiKey's keys at
  login and whenever it is plugged in: SSH, signed commits and sops work.
- GitHub's SSH host key is pinned (no "trust this host?" question).
- Mullvad logs in by itself once the network is up (`mullvad-login`, retries
  until it works, re-checks every 15 min).
- `~/.nix-config` becomes a checkout of **GitHub's current main**, plus only
  what the install added (`keys/hosts/<host>.age`, the disk if `--disk` was
  used). A stick older than the repo therefore never overwrites newer files.
  Then `.sops.yaml` is regenerated and, with the YubiKey plugged in, the
  secrets are re-encrypted (PIN prompt) and committed. A notification tells
  you when it's done:
  ```sh
  cd ~/.nix-config && git push
  ```
  Without the YubiKey at that moment the notification says what to run
  (`sops-sync`, commit, push).

What is left for you: logging in to accounts (browser, ...).

If you restored a backup that contained a checkout, the installer puts the
files there instead: run `sops-sync`, commit, push.

## Making a host installable

The stick includes every host of this architecture whose config has a disko
layout. For a new or existing host:

1. Import the disk layout and, for an impermanent root, the impermanence
   module (see `hosts/laptop/default.nix`, `hosts/vps/default.nix`):
   ```nix
   (import ../_shared/components/impermanence/disko.nix {
     device = "/dev/disk/by-id/...";   # `ls -l /dev/disk/by-id` on that machine
     swapSize = "8G";
     # encrypt = false;  biosBoot = true;   # e.g. servers / legacy BIOS
   })
   ../_shared/components/impermanence   # or ../_shared/components/server
   ```
   and remove `fileSystems`, `swapDevices` and LUKS devices from its
   `hardware-configuration.nix` (disko defines them now).
2. Check it in a VM:
   `nix run .#nixosConfigurations.<host>.config.system.build.vmWithDisko`.
3. Rebuild the stick. `install-host <host>` now offers it. Its role
   (`host.role`, `server` via the server module) decides which secrets it
   gets.

Like for the desktop: don't `nixos-rebuild switch` a running host onto a disko
layout; reinstall it.
