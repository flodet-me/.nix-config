# 0002: Impermanent root on btrfs, state kept only where declared

Date: 2026-11-27. Status: accepted, implemented on all four hosts
([impermanence.md](../impermanence.md)).
Recorded after the fact on 2026-11-27.

## Context

On a normal root, state collects outside the config: stray files in `/etc`
and `/var`, files in `/tmp` and `/root`, state from services that isn't
declared (docs/impermanence.md lists these as what a reboot now deletes).
Why removing that mattered is not recorded beyond the "Erase your darlings"
comment in the module.

## Options

1. A normal persistent root: the earlier ext4 installs (`a66fda6^`,
   `hosts/desktop/hardware-configuration.nix`).
2. btrfs: replace the root subvolume with an empty one on every boot and
   keep listed paths in `/persist` (nix-community/impermanence).
3. A tmpfs root (obvious alternative; reason for not choosing it not
   recorded).

## Decision

Option 2. Disk layout from `impermanence/disko.nix` (LUKS on the
workstations, plain btrfs on the servers); an initrd `rollback` service moves
the old root to `/old_roots` (kept 7 days) and creates an empty one. Only
`/nix`, `/home`, `/boot` and `/persist` survive. Workstations keep a curated
persist list; servers set `impermanence.persistVarLib`, so all of `/var/lib`
persists and any enabled service keeps its state and is backed up without
being listed. On the workstations `~/.cache` is its own subvolume
(`cacheSubvolume`): caches churn and can be rebuilt, so they stay out of the
hourly `/home` snapshots but survive reboots.

## Consequences

- The persist list needs upkeep: a new workstation service with state in
  `/var/lib` or `/etc` must be added, or it loses that state at the next
  reboot. `fs-diff` shows what the next boot deletes.
- New paths must be copied into `/persist` before rebooting; missed ones can
  be recovered from `/old_roots` for 7 days, and big temporary files in `/tmp`
  or `/root` occupy the disk that long.
- Moving a host to this layout means a reinstall that wipes the disk.
- The sops host key must live on `/persist` and be read from there directly,
  since secrets are decrypted before the bind mounts exist (ADR 0003).
- Rootless Docker data sits in `~/.cache`, outside the `/home` snapshots.

## Evidence

- `hosts/_shared/components/impermanence/default.nix`, `disko.nix`,
  `names.nix`; `hosts/_shared/components/server/default.nix`
  (`persistVarLib`); `hosts/desktop/default.nix`, `hosts/laptop/default.nix`
  (`cacheSubvolume`); [impermanence.md](../impermanence.md); AGENTS.md,
  "Impermanence & Storage".
- `a66fda6` (2026-11-06): impermanence module, disko layout with LUKS,
  `persistVarLib`, `fs-diff`, docs. `2b6ede5` (2026-11-07): `names.nix`.
  `b7f0436` (2026-11-07): `cacheSubvolume`. `5281859` (2026-11-27): rootless
  Docker data in `~/.cache`.

Decided by: user (recorded by agent).
