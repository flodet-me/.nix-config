# 0004: nixos-unstable as the only nixpkgs channel

Date: 2026-11-27. Status: accepted, implemented (`flake.nix`).
Recorded after the fact on 2026-11-27.

## Context

All hosts and home-manager follow one `nixpkgs` input. The flake started on
the stable release `nixos-24.11` with home-manager `release-24.11`. Why it
moved to unstable is not recorded (the commits are "wip"). A stable input
was kept next to it as a fallback for broken packages until 2026-11-27,
when it was removed because nothing used it (AGENTS.md, Conventions).

## Options

1. A stable release as the main channel (the flake's start, `113c760`).
2. unstable as main with a stable input (`nixpkgs-stable`, `pkgs.stable`)
   for packages broken on unstable (`3b6e8c3` to `fafd8b8`).
3. unstable only; pin an input for a package only when it breaks.

## Decision

Option 3. `nixpkgs` is `github:nixos/nixpkgs/nixos-unstable`; every input
that takes a nixpkgs (home-manager master, sops-nix, disko, impermanence,
stylix, ...) follows it. When an unstable package is broken, a pinned input
for that package is added then, not in advance.

## Consequences

- One nixpkgs in `flake.lock`; no unused second channel to update.
- Updates (`nix flake update`, reserved for a human, or the weekly CI job
  that opens a `flake.lock` update PR for a human to merge,
  docs/security-updates.md) can break a package or option at any time; there
  is no prepared fallback, so a fix means adding a pinned input then.
- A CVE fixed in nixpkgs but not yet in the locked revision: wait for the
  next update or pin an input with the fix (docs/security-updates.md).
- `stateVersion` stays at each machine's first-install release and is not
  raised with the channel.

## Evidence

- `flake.nix` (`nixpkgs.url`, `inputs.*.follows`), `overlays/default.nix`,
  AGENTS.md ("Conventions"), [security-updates.md](../security-updates.md).
- `113c760` (2024-12-27): init on `nixos-24.11`. `485c7ee` (2025-01-09):
  `nixpkgs-unstable` added as a second input. `3b6e8c3` (2025-01-25):
  `nixpkgs` becomes `nixos-unstable`, stable kept as `nixpkgs-stable`,
  home-manager on master. `155cce0` (2026-06-05): stable input moved to
  `nixos-26.05`. `e43943d`, `fafd8b8` (2026-11-27): `nixpkgs-stable` and the
  `pkgs.stable` overlay removed.

Decided by: user (recorded by agent).
