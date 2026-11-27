# 0006: winvm lives in nix-config as `pkgs.winvm`, its data in `WINVM_HOME`

Date: 2026-11-27. Status: accepted, implemented on `desktop` and `laptop`
([pkgs/winvm/README.md](../../pkgs/winvm/README.md)).

## Context

winvm (Windows test VMs on QEMU/KVM) was its own repository,
`~/Projects/windows-vm`, used from its checkout through its own flake's
`nix develop`. Code and data shared one tree: `state/` (base images and VMs,
~130 GB on desktop), `iso/`, `cache/`, `share/`, `runs/`, `captures/`,
`config.local.env`, `images/*.local.env` and new recipes were written next to
the scripts. Repository jails (ADR 0001) and both workstations want winvm on
PATH, from one place, with the code read-only.

## Options

1. Keep the separate repository and install it from a flake input.
2. Move it into nix-config, run it from the checkout as before.
3. Move it into nix-config as a package: code read-only in the store, data in
   a directory of its own.

For the data directory: `~/Projects/windows-vm` everywhere (only desktop has
it on the unsnapshotted data disk), `~/.cache/winvm` (outside the snapshots,
but VMs are not a cache), or `${XDG_DATA_HOME:-~/.local/share}/winvm` kept out
of the `/home` snapshots another way.

## Decision

Move into nix-config, with its history (`git subtree add`, not squashed),
as `pkgs/winvm`: decided by the user (goal G-9). Option 3, package and layout
details decided by the agent:

- `pkgs.winvm` copies the tree to `share/winvm` and wraps `winvm` with its
  runtime tools (the old dev shell's list, powershell for the IDE setups,
  without wireshark-cli) and `WINVM_OVMF_DIR`; bash and zsh completion.
- Everything winvm writes or you configure lives in `WINVM_HOME`: `state/`,
  `iso/`, `cache/`, `share/`, `runs/`, `captures/`, `recipes/` (yours),
  `config.local.env`, `images/NAME.local.env`. Shipped settings and recipes
  stay in the package; a shipped recipe wins over one of the same name.
- The home is `$WINVM_HOME` if set, else the first line of
  `${XDG_CONFIG_HOME:-~/.config}/winvm/home` (absolute, or winvm refuses),
  else `${XDG_DATA_HOME:-~/.local/share}/winvm`, the default, used on the
  laptop. The first writing command creates it as a btrfs subvolume of its
  own (nested subvolumes are not part of the hourly btrbk snapshots of
  `/home`, so VM images stay out of them) with `chattr +C`; on other file
  systems a plain directory.
- desktop: `~/Projects/windows-vm` in `~/.config/winvm/home` (home-manager
  `xdg.configFile`), the old checkout with its data on the data disk, not
  snapshotted. Nothing is moved. A file instead of a session variable: the
  session environment changes only at the next login, and a winvm started
  before that would have created and used an empty default home.
- Only commands that may write create the home; reads and typos do not.

## Consequences

- Changing winvm is a nix-config change: try it with `nix run .#winvm --`,
  get it on PATH with a switch. `pkgs/winvm/test.nix` (no VM) runs in the
  Check.
- In a jail, only data paths need binds (docs/agent-isolation.md).
- `winvm vscode setup` / `rider setup` write store paths into IDE files;
  after an update and garbage collection they must be run again.
- A home is removed with `rm -r` (an empty subvolume goes like a
  directory, also with `rmdir`).
- The laptop's VMs survive reinstalls only as far as `/home` does, but are in
  no snapshot; base images are rebuilt with `winvm build`.
- The old repository `~/Projects/windows-vm` keeps its git history and is no
  longer developed; its code copies there are ignored by the packaged winvm.

Decided by: user (the move into nix-config with its history, goal G-9);
agent (the package, the `WINVM_HOME` layout, its default and the per-host
values).
