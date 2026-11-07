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
   as `nixos`. The stick is for `desktop`, `laptop` and `moon`; `vps` is a
   legacy-BIOS cloud template and is installed over the network instead
   (`provision-server`, docs/cloud.md).
3. Plug in the YubiKey and run:
   ```sh
   sudo install-host laptop                       # without argument: lists the hosts on the stick
   sudo install-host laptop --disk /dev/nvme0n1   # if the configured disk differs
   ```
   It shows every disk of the host that will be erased (the desktop has two: the
   system SSD and the 860 EVO mounted at `/data`) and asks for the host name
   before erasing them, then:
   - formats them (encrypted hosts, desktop and laptop, ask for the new disk
     passphrase; moon and vps are unencrypted),
   - offers to enroll a YubiKey for disk unlock (see below),
   - generates the host's sops key in `/persist/var/lib/sops-nix/key.txt`,
   - asks `Register the new key ...? [y/N]`: Enter means no, and the secrets
     are then missing until you run `sops-sync` later. With `y`: registers it
     (`sops-register-host`: `keys/hosts/<host>.age` + `sops-sync`, YubiKey
     PIN) and checks the new key can decrypt the host's secrets,
   - optionally pauses so you can restore data into `/mnt` (e.g.
     `rsync -aHAX /path/to/backup/home/ /mnt/home/`),
   - builds and installs the system, offline.
4. The script unmounts `/mnt`, turns the swap file off and closes the disk, so
   the live system can restart cleanly. Reboot, remove the stick.

### YubiKey disk unlock (desktop, laptop)

After formatting, `install-host` asks `Enroll a YubiKey now?`. With `y` you
enter the passphrase you just set, then the key's **FIDO2 PIN** (set one first
with `ykman fido access change-pin`; it is not the OpenPGP PIN), then touch it.
It asks again, so a second key can be added as a spare. At boot the disk then
asks for the PIN and a touch. The passphrase stays valid as a fallback, and
without an enrolled or plugged-in key the prompt is the plain passphrase.
Later, enroll by hand:
`sudo systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=yes /dev/<luks-partition>`.
The boot side (`crypttabExtraOpts = [ "fido2-device=auto" ]`) is in
`hosts/_shared/components/impermanence/disko.nix`. Not testable in a VM (no
YubiKey): try it once with the key unplugged (passphrase prompt), then plugged in.

## If the install fails

`install-host` says which step failed, releases `/mnt` and the encrypted disk
and tells you to run it again: a second run wipes the disk again and starts
clean, so there is nothing to undo by hand. The error itself is above
(Shift+PageUp). Typical causes: a disk too small for the swap file
(`swapSize` in the host), a wrong LUKS passphrase typed twice differently, or a
YubiKey that is not plugged in when asked (answer `n` to registration and run
`sops-sync` later). `provision-server` (cloud servers) likewise names the step;
the keys it generated are shredded, so run it again.

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

Servers (`moon`) have no home-manager, so there is no automatic checkout: the
copy of the repo in `~/.nix-config` is only a record of what was installed.
Register the key from your workstation (`sops-sync`, commit, push) and deploy,
see docs/cloud.md.

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
   (the LUKS mapper name, the sops key path and the disk are read from the
   evaluated config, so no script needs editing) and remove `fileSystems`,
   `swapDevices` and LUKS devices from its
   `hardware-configuration.nix` (disko defines them now).
2. Check it in a VM:
   `nix run .#nixosConfigurations.<host>.config.system.build.vmWithDisko`.
3. Rebuild the stick. `install-host <host>` now offers it. Its role
   (`host.role`, `server` via the server module) decides which secrets it
   gets.

**Extra data disks:** `hosts/_shared/components/data-disk.nix` adds one (LUKS,
then btrfs with zstd, mounted at `/data`, owned by the user), as the desktop does
with its 860 EVO. It is part of the disko layout, so every `install-host` run
erases it too; keep anything you need elsewhere. `--disk` only changes the
system disk.

How it is unlocked: `install-host` makes a random key, formats the disk with it
and stores it on the encrypted system disk (`/persist/etc/data-disk.key`, mode
400); the temporary copy is shredded, also when the install fails. After boot,
once the system disk is open, `/etc/crypttab` unlocks the data disk with that
key, so there is only the one passphrase (or YubiKey) at boot. The disk is
`nofail`: if it is missing or cannot be opened, the machine still boots and
`/data` is simply absent. **The key lives only on the system disk**, so if that
is lost, the data disk is unreadable. Add a passphrase as a second way in, once,
after the first boot (choose one you will remember):

```sh
sudo cryptsetup luksAddKey /dev/disk/by-partlabel/disk-data-luks --key-file /persist/etc/data-disk.key
```

With that, `sudo cryptsetup open /dev/disk/by-partlabel/disk-data-luks data-crypt` and
the passphrase open it by hand on any machine. In a `vmWithDisko` VM the disk
uses the password `disko` (test only).

**What lives where on the desktop:**

- `/data/steam` is the Steam library. Add it once in Steam: Settings → Storage →
  add folder (Steam keeps that choice in its config in `/home`).
- `~/Projects` and `~/Games` are bind mounts of `/data/projects` and `/data/games`
  (`homeBinds` in `hosts/desktop/default.nix`), so source trees, their build output
  (Rust `target`, .NET `bin`/`obj`) and Lutris/Heroic/Wine games are on the data
  disk. A bind mount, not a symlink: a restored backup containing a real
  `~/Projects` would make a home-manager link fail at activation, while a mount
  just covers it.
- `~/.cache` is its own btrfs subvolume (`cacheSubvolume` in the disko layout, on
  desktop and laptop). NuGet (`NUGET_PACKAGES`) and npm (`NPM_CONFIG_CACHE`) caches
  are pointed into it.
- Snapshots: a snapshot of `/home` does not contain what is behind a mount or in
  another subvolume. So `~/.cache`, the games and all projects are not in the
  `/home` snapshots (nor in `impermanence.sendSnapshotsTo`); only empty directories
  are. **Your source code on `/data/projects` is therefore not backed up by
  anything here**: keep it in git and push, or back `/data` up yourself.
- `install-host` erases `/data` (everything on it, projects included) and
  re-creates the empty folders. Restore a backup of your projects into
  `/mnt/data/projects` during the install pause, not into `/mnt/home/…/Projects`
  (which would be covered by the mount and invisible).

Like for the desktop: don't `nixos-rebuild switch` a running host onto a disko
layout; reinstall it.
