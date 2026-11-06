# Impermanence

`desktop` and `laptop` wipe their root filesystem on every boot. Only these survive:

| Path       | What                                                              |
| ---------- | ----------------------------------------------------------------- |
| `/nix`     | The store. Cleaned by `nix.gc` (weekly, >30d), not by reboots.    |
| `/home`    | Kept entirely: projects, dotfiles, caches.                        |
| `/persist` | System state listed in `environment.persistence."/persist"`.      |
| `/boot`    | ESP.                                                              |

Everything else (stray files in `/etc` and `/var`, `/tmp`, `/root`, state from
services that isn't declared) is gone after a reboot.

Config: `hosts/_shared/components/impermanence/` (`disko.nix` = disk layout,
`default.nix` = rollback + persist list).

## Day to day

- `fs-diff` lists every file currently on the ephemeral root, i.e. what the
  next reboot deletes. Run it after setting up something new.
- To keep a path, add it to `directories`/`files` in
  `impermanence/default.nix`, rebuild, and copy the current contents into
  `/persist/<path>` **before** rebooting.
- Forgot something? The previous roots are kept for 30 days:
  ```sh
  sudo mount -o subvol=/ /dev/mapper/crypted /mnt
  ls /mnt/old_roots/
  ```

## Snapshots and scrub

- btrbk snapshots `/home` hourly into `/.snapshots` (kept: all for 2 days, then
  48 hourly, 14 daily, 4 weekly). Restore by copying out of
  `/.snapshots/home.<timestamp>/`. These are not backups: same disk.
- Deleted files in `/home` only free space once the last snapshot holding them
  expires (up to ~4 weeks).
- `btrfs scrub` runs monthly (`btrfs-scrub@-.timer`); check results with
  `sudo btrfs scrub status /`.

## Testing in a VM

```sh
nix run .#nixosConfigurations.laptop.config.system.build.vmWithDisko
```

Works for every impermanent host (desktop, laptop, servers). LUKS passphrase is
`disko`, user `flodet` with the config's password. Disk size (room for swap),
memory and the desktop's nvidia assertion are preset for this VM. Secrets are
missing in it (the VM's key isn't registered), which is expected.

## Migrating a host (reinstall, wipes the disk)

Easiest: the installer stick (`docs/installer.md`), which automates the steps
below. Switching an existing ext4 install to this config does **not** work. Do not
run `nixos-rebuild switch` on a host that hasn't been reinstalled.

1. Back up `/home/flodet` (including `~/.gnupg`) and, if wanted,
   `/etc/NetworkManager/system-connections`,
   `/var/lib/docker`, `/var/lib/libvirt`.
2. Boot a NixOS installer, get this repo onto it, check the target disk with
   `lsblk` (it must match `device` in the host's `default.nix`).
3. Partition, format and mount (asks for the new LUKS passphrase):
   ```sh
   sudo nix --experimental-features "nix-command flakes" run \
     github:nix-community/disko/latest -- --mode destroy,format,mount --flake .#<HOST>
   ```
4. Restore data:
   ```sh
   sudo rsync -aHAX <backup>/home/ /mnt/home/
   sudo mkdir -p /mnt/persist/etc/NetworkManager
   sudo rsync -a <backup>/system-connections /mnt/persist/etc/NetworkManager/
   ```
5. Create the host's sops key and register it (needs the YubiKey on some
   machine; details in `docs/secrets.md`):
   ```sh
   sudo mkdir -p /mnt/persist/var/lib/sops-nix
   sudo nix --extra-experimental-features "nix-command flakes" shell nixpkgs#age \
     -c age-keygen -o /mnt/persist/var/lib/sops-nix/key.txt   # prints the public key
   # add it to .sops.yaml, `sops updatekeys -y` each secrets file, commit + push
   ```
   Skipping this still boots, but secrets (e.g. Mullvad login) stay missing
   until the key is registered and you switch again.
6. Install and reboot:
   ```sh
   sudo nixos-install --flake .#<HOST> --no-root-passwd
   ```
