# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is a personal Nix flake managing NixOS system configs and home-manager user configs across several machines.

## Commands

```sh
# Enter the dev shell (provides sops, nixfmt, nix-output-monitor, claude-code, etc.)
nix develop            # on a configured system with flakes enabled
nix-shell              # on a blank NixOS install (bootstraps the same tooling)
# direnv (.envrc: `use flake`) enters the shell automatically on cd.

# Apply a NixOS host config (host = desktop | laptop | moon | portal)
nixos-rebuild switch --flake .#<HOST>
# Build without switching (nom = nix-output-monitor, in the dev shell):
nixos-rebuild build --flake .#<HOST> |& nom

# Format all Nix files (RFC style, this repo's `formatter`)
nixfmt **/*.nix        # or: nix fmt

# Update flake inputs
nix flake update       # all inputs
nix flake lock --update-input nixpkgs   # single input
```

## Architecture

**Entry point is `flake.nix`.** It defines four `nixosConfigurations`:
`desktop`, `laptop` (full graphical workstations) and `moon`, `portal` (headless
servers). `inputs` and `outputs` (`self`) are threaded to every module via
`specialArgs`/`extraSpecialArgs`, so modules can reference `inputs.<flake>` and
`outputs.overlays` directly.

**home-manager wiring:** only `desktop` and `laptop` include home-manager — it's
attached as a NixOS module (`home-manager.nixosModules.home-manager`) in
`flake.nix`, so a single `nixos-rebuild switch` applies both system and user
config together (there is no separate `home-manager switch` step). `moon` and
`portal` are system-only with no home-manager. `portal` is a Raspberry Pi that is
still mostly commented-out boilerplate and doesn't even import the shared globals.

**Two parallel trees, both using the same `_shared` + per-host layering pattern:**

- `hosts/` — NixOS (system) config. Each host's `default.nix` imports
  `_shared/global.nix` plus an à-la-carte list of `_shared/components/*.nix`
  (e.g. `pipewire.nix`, `nvidia-graphics-driver.nix`, `gaming.nix`). Hardware
  quirks come from `nixos-hardware` modules and the host's
  `hardware-configuration.nix`. `hosts/_shared/global.nix` is imported by most
  hosts and sets up sops-nix, overlays, nixpkgs config, binary caches, and the
  `flodet` user.
- `home/flodet/` — home-manager (user) config, same shape:
  `<host>/default.nix` imports `_shared/global.nix` (CLI tools: zsh, git, tmux,
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

## Secrets (sops-nix)

Secrets are SOPS-encrypted and decrypted at activation time via sops-nix.
`.sops.yaml` defines the encryption rules:

- `home/**/secrets.{yaml,json,env,ini}` → encrypted to flodet's **PGP** key + the desktop **age** key.
- `hosts/_shared/**/secrets.{yaml,json,env,ini}` → encrypted to the desktop **age** key only.

Host age keys are derived from the machine's SSH host key (`ssh-to-age`). Edit
secrets with `sops <path/to/secrets.yaml>` from inside the dev shell. See
`docs/secrets.md` and `docs/yubikey.md`. YubiKey/GPG is used for auth
(`yubikey-gpg.nix` exists in both trees).

## Conventions

- `.editorconfig` governs style; Nix files are formatted with `nixfmt` (RFC style). Run the formatter before committing.
- `stateVersion` in host/home configs is intentionally pinned to the first-install release — do not bump it casually.
- Prefer `pkgs.stable.<pkg>` (via the overlay) when an unstable package is broken, rather than pinning inputs.
