# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is a personal Nix flake managing NixOS system configs and home-manager user configs across several machines.

## Commands

```sh
# Enter the dev shell (provides sops, nixfmt, nix-output-monitor, claude-code, etc.)
nix develop            # on a configured system with flakes enabled
nix-shell              # on a blank NixOS install (bootstraps the same tooling)
# direnv (.envrc: `use flake`) enters the shell automatically on cd.

# Apply a NixOS host config (host = desktop | laptop | moon | vps)
nixos-rebuild switch --flake .#<HOST>
# Build without switching (nom = nix-output-monitor, in the dev shell):
nixos-rebuild build --flake .#<HOST> |& nom

# Format all Nix files (RFC style, this repo's `formatter`)
nixfmt **/*.nix        # or: nix fmt

# Workflow scripts (dev shell, sources in scripts/):
make-installer-stick                       # build offline installer ISO, write+verify USB stick
installer-vm [--boot]                      # try the installer in QEMU
sops-register-host <host> <age-pubkey>     # add/replace a host key (keys/hosts/), then sops-sync
sops-sync                                  # regenerate .sops.yaml + re-encrypt (YubiKey)
provision-server <host> root@<ip>          # first install of a cloud server
check-cves [host...]                       # known CVEs in what the hosts run (docs/security-updates.md)
claude-plugins-sync                        # install declared Claude Code plugins now (also runs as user service; docs/claude-code.md)
# Deploy to a server
nixos-rebuild switch --flake .#<server> --target-host <server> --sudo
# Boot any impermanent host in a VM (LUKS passphrase: disko)
nix run .#nixosConfigurations.<HOST>.config.system.build.vmWithDisko

# Update flake inputs
nix flake update       # all inputs
nix flake lock --update-input nixpkgs   # single input
```

## Architecture

**Entry point is `flake.nix`.** It defines `nixosConfigurations`:
`desktop`, `laptop` (full graphical workstations), `moon` (home server: DNS
with ad blocking, containers) and `vps` (cloud server template, `docs/cloud.md`), all built by
the `mkHost` helper (`user = true` adds home-manager). The offline installer
lives in `installer/` and is only exposed as `packages.x86_64-linux.installer-iso`
(`docs/installer.md`); it is not a host. `inputs` and `outputs` (`self`) are threaded to every module via
`specialArgs`/`extraSpecialArgs`, so modules can reference `inputs.<flake>` and
`outputs.overlays` directly.

**home-manager wiring:** only `desktop` and `laptop` include home-manager — it's
attached as a NixOS module (`home-manager.nixosModules.home-manager`) in
`flake.nix`, so a single `nixos-rebuild switch` applies both system and user
config together (there is no separate `home-manager switch` step). `moon` and
`vps` are system-only servers (no home-manager), built on
`hosts/_shared/components/server`.

**Two parallel trees, both using the same `_shared` + per-host layering pattern:**

- `hosts/` — NixOS (system) config. Each host's `default.nix` imports
  `_shared/global.nix` plus an à-la-carte list of `_shared/components/*.nix`
  (e.g. `pipewire.nix`, `nvidia-graphics-driver.nix`, `gaming.nix`). Hardware
  quirks come from `nixos-hardware` modules and the host's
  `hardware-configuration.nix`. `hosts/_shared/global.nix` is imported by most
  hosts and sets up sops-nix, overlays, nixpkgs config, binary caches, and the
  `flodet` user.
- `home/flodet/` — home-manager (user) config, same shape:
  `<host>/default.nix` imports `_shared/global.nix` (CLI tools: zsh, git,
  fzf, bat, direnv, neovim), optionally `_shared/desktop.nix` (GUI apps +
  stylix theming), and cherry-picks `_shared/components/*` and
  `_shared/desktop-environments/*` (gnome, hyprland).

**Adding functionality:** write a self-contained module under the appropriate
`_shared/components/` directory, then add it to the relevant host/user
`default.nix` `imports` list. Components are opt-in per host — nothing is global
unless imported by `global.nix`.

**Overlays (`overlays/default.nix`)** expose:
`pkgs.inputs.<flake>` (packages from each flake input),
`pkgs.stable` (the pinned `nixpkgs-stable` set, currently 26.05, vs. the
unstable default), plus `additions` (custom packages from `pkgs/`, currently
empty) and `modifications` (patched packages). All overlays are applied in
`hosts/_shared/global.nix`.

## Impermanence

`desktop` and `laptop` use btrfs on LUKS (layout declared with disko) and replace
the root subvolume with an empty one on every boot. Only `/nix`, `/home`, `/boot`
and paths declared in `hosts/_shared/components/impermanence/default.nix`
(stored in `/persist`) survive. When enabling a NixOS service that keeps state
under `/var/lib` or `/etc`, add that path to the persist list. See
`docs/impermanence.md`.

## Secrets (sops-nix)

Secrets are SOPS-encrypted and decrypted at activation time via sops-nix,
**system-level only** (no home-manager sops). `.sops.yaml` has a single key
group per file, so any one recipient decrypts: flodet's **PGP** key (YubiKey,
admin) plus one **age** key per host, stored at
`/persist/var/lib/sops-nix/key.txt` (impermanent hosts) or
`/var/lib/sops-nix/key.txt`. Workstation secrets are declared in
`hosts/_shared/users/flodet/workstation.nix` (user-session ones with `owner = "flodet"`)
and and read from
home-manager via `osConfig.sops.secrets.<name>.path`. Never reference a secret's
value in Nix, only its path. Servers get their own rule and only read
`hosts/<server>/secrets.yaml` (host keys in `keys/hosts/<host>.age`, admins in `keys/admins`, role from `host.role`; `.sops.yaml` is generated by `sops-sync`, never edit it). `checks.<system>.sops-encrypted` (also in CI)
fails on plaintext in `*secrets.yaml`.

Edit secrets with `sops <path/to/secrets.yaml>` from inside the dev shell. See
`docs/secrets.md` (incl. adding a host) and `docs/yubikey.md`. YubiKey/GPG is
used for auth (`yubikey-gpg.nix` exists in both trees).

## Claude Code plugins

Plugins, skills and MCP servers are declared in `home/flodet/_shared/components/claude-code/default.nix`
(system half: `hosts/_shared/components/claude-code.nix`); activation merges
them into the (writable) `~/.claude/settings.json`, and the
`claude-plugins-sync` user service downloads them automatically. Add any
runtime tool a plugin calls to that module's `home.packages`, and document
new plugins in `docs/claude-code.md`.

## Conventions

- `.editorconfig` governs style; Nix files are formatted with `nixfmt` (RFC style). Run the formatter before committing.
- `stateVersion` in host/home configs is intentionally pinned to the first-install release — do not bump it casually.
- Prefer `pkgs.stable.<pkg>` (via the overlay) when an unstable package is broken, rather than pinning inputs.
