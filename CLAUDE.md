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
nh os switch           # same for this machine, shows what changes first (alias: `update`)
# Build without switching (nom = nix-output-monitor, in the dev shell):
nixos-rebuild build --flake .#<HOST> |& nom

# Format all Nix files (RFC style, this repo's `formatter`)
nixfmt $(git ls-files '*.nix')

# Run the CI workflows locally (needs Docker; `act` is in the dev shell).
# One-time: docker build -t ubuntu-act-nix:local .github/act   (.actrc selects it)
act -W .github/workflows/nix.yml -j format
act -W .github/workflows/nix.yml -j build --matrix host:vps

# Workflow scripts (dev shell, sources in scripts/):
make-installer-stick                       # build offline installer ISO, write+verify USB stick
installer-vm [--boot]                      # try the installer in QEMU
sops-register-host <host> <age-pubkey>     # add/replace a host key (keys/hosts/), then sops-sync
sops-sync                                  # regenerate .sops.yaml + re-encrypt (YubiKey)
provision-server <host> root@<ip>          # first install of a cloud server
check-cves [host...]                       # known CVEs in what the hosts run (docs/security-updates.md)
claude-plugins-sync                        # install declared Claude Code plugins now (also runs as user service; docs/claude-code.md)
# On the installer stick (not in the dev shell): sudo install-host <host>   (docs/installer.md)
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
the `mkHost` helper (`user = true` adds home-manager). `mkHost` also sets
`host.user`, the one login user (`username` in `flake.nix`). The offline installer
lives in `installer/` and is only exposed as `packages.x86_64-linux.installer-iso`
and `install-host` (`docs/installer.md`); it is not a host. `inputs` and `outputs` (`self`)
are threaded to every module via `specialArgs`/`extraSpecialArgs`, so modules can
reference `inputs.<flake>` and `outputs.overlays` directly.

**Host facts** (`hosts/_shared/components/host-role.nix`): `host.role`
(`workstation` or `server`, read by `sops-sync` and `install-host`) and
`host.user`. Modules read `config.host.user` instead of hardcoding the name.

**home-manager wiring:** only `desktop` and `laptop` include home-manager — it's
attached as a NixOS module (`home-manager.nixosModules.home-manager`) in
`flake.nix`, so a single `nixos-rebuild switch` applies both system and user
config together (there is no separate `home-manager switch` step). `moon` and
`vps` are system-only servers (no home-manager), built on
`hosts/_shared/components/server`.

**Two parallel trees, both using the same `_shared` + per-host layering pattern:**

- `hosts/` — NixOS (system) config. Every host imports `_shared/global.nix`
  (sops-nix, overlays, nixpkgs config, nix settings and binary caches, zsh,
  privacy). Workstations then import `_shared/components/workstation.nix`, one
  bundle with the login user, GNOME, YubiKey, VPNs, theming and upkeep; servers
  import `_shared/components/server`. A host adds only its hardware
  (`nixos-hardware` modules, `hardware-configuration.nix`), disk layout
  (`impermanence/disko.nix`), hostname and extras (`nvidia-*`, `gaming.nix`, `data-disk.nix`, an encrypted second disk, ...).
- `home/flodet/` — home-manager (user) config, same shape:
  `<host>/default.nix` imports `_shared/global.nix` (CLI tools: zsh, git,
  fzf, bat, direnv, neovim) and `_shared/desktop.nix` (GUI apps, GNOME,
  stylix theming, Claude Code, YubiKey, ...) and adds host-specific packages.

**Adding functionality:** write a self-contained module under the appropriate
`_shared/components/` directory, then import it from `workstation.nix` (both
workstations), from one host, or from `server/` (servers). Nothing is global
unless imported by `global.nix`.

**Overlays (`overlays/default.nix`)** expose:
`pkgs.inputs.<flake>` (packages from each flake input),
`pkgs.stable` (the pinned `nixpkgs-stable` set, currently 26.05, vs. the
unstable default; evaluated only where used), plus `additions` (custom
packages from `pkgs/`, currently empty) and `modifications` (patched
packages). All overlays are applied in `hosts/_shared/global.nix`.

## Impermanence

All four hosts use btrfs (layout declared with disko; LUKS-encrypted on
`desktop` and `laptop`, plain on `moon` and `vps`) and replace the root
subvolume with an empty one on every boot. Only `/nix`, `/home`, `/boot`
and paths declared in `hosts/_shared/components/impermanence/default.nix`
(stored in `/persist`; all of `/var/lib` on servers) survive. When enabling a NixOS
service that keeps state under `/var/lib` or `/etc` on a workstation, add that
path to the persist list. Names shared with the installer (LUKS mapper, sops
key path) live in `impermanence/names.nix`. See `docs/impermanence.md`.

Big, re-creatable data stays out of the `/home` snapshots: `~/.cache` is its own
subvolume (`cacheSubvolume` in `impermanence/disko.nix`, workstations), and the
desktop bind-mounts `~/Projects` and `~/Games` from its encrypted second disk
(`components/data-disk.nix`, `homeBinds`; erased on every install, so projects
there must be in git). A caller of `data-disk.nix` creates the folders through
its `directories`/`homeBinds` arguments.

Workstation upkeep (zram, earlyoom, journal and coredump caps, SMART alerts,
hibernate delay) is in `components/workstation-health.nix`; libvirt, with the
repair of its secrets key after a reinstall, in `components/libvirt.nix`.

## Secrets (sops-nix)

Secrets are SOPS-encrypted and decrypted at activation time via sops-nix,
**system-level only** (no home-manager sops). `.sops.yaml` has a single key
group per file, so any one recipient decrypts: flodet's **PGP** key (YubiKey,
admin) plus one **age** key per host, stored at
`/persist/var/lib/sops-nix/key.txt` on every host. Workstation secrets are declared
next to what uses them (e.g. `mullvad-account-key` in `mullvad-vpn.nix`, file
`hosts/_shared/users/flodet/user-secrets.yaml`); user-session ones use
`owner = config.host.user` and are read from home-manager via
`osConfig.sops.secrets.<name>.path`. Never reference a secret's
value in Nix, only its path. Servers get their own rule and only read
`hosts/<server>/secrets.yaml` (host keys in `keys/hosts/<host>.age`, admins in `keys/admins`, role from `host.role`; `.sops.yaml` is generated by `sops-sync`, never edit it). `checks.<system>.sops-encrypted` (also in CI)
fails on plaintext in `*secrets.yaml`. The login password is not a secret: it is
`123456789` on purpose (`docs/secrets.md`).

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

## Testing and running things

Do not `nixos-rebuild switch` the machine you are on to test: build instead.
Everything below runs without sudo and without the YubiKey. New files must be
known to git (`git add -N <file>`) or flakes will not see them.

**Quick checks (after any Nix change)**

```sh
nixfmt $(git ls-files -co --exclude-standard '*.nix')   # not `nix fmt`: it hung once
nix flake check --no-build                              # evaluates packages, checks, hosts
for h in laptop desktop moon vps; do                    # all four must build
  nix build --no-link .#nixosConfigurations.$h.config.system.build.toplevel
done
nix eval .#nixosConfigurations.<host>.config.<option>                              # inspect a system option
nix eval .#nixosConfigurations.laptop.config.home-manager.users.flodet.<option>    # ... or a home option
nix run nixpkgs#deadnix -- -l .                         # unused arguments (`-e` edits: rebuild after, callers may pass them)
```

**Prove a refactor changed nothing:** before editing, record
`nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath`
for each host. Afterwards `nix build "<old drv>^out"` and the new toplevel, then
`nix store diff-closures <old> <new>` (packages) and `diff -rq <old>/ <new>/`
(generated files such as `etc/`, `kernel-params`). Only intended differences
may remain; `nix-diff` is too verbose to read.

**Scripts and workflows**

```sh
nix build --no-link .#install-host            # also runs shellcheck on the installer script
nix shell nixpkgs#shellcheck -c shellcheck -S warning scripts/<name>/<name>.sh
nix run nixpkgs#actionlint -- .github/workflows/*.yml
act -W .github/workflows/nix.yml -j format    # run a CI job in Docker (one-time image build: see Commands)
act -W .github/workflows/nix.yml -j build --matrix host:vps
act -W .github/workflows/security.yml -j cves --matrix host:vps   # fails when CVEs are found: that is its job
```

`act` works for `hosts`, `format`, `installer`, `build` and `cves`; the `update`
job needs a real token and cannot be tried. If a step fails only under `act`,
check `if: ${{ !env.ACT }}` first.

**Run a host in a VM** (needs `/dev/kvm`; LUKS passphrase `disko`, login
password `123456789`):

```sh
nix build .#nixosConfigurations.<host>.config.system.build.vmWithDisko -o /tmp/vm
QEMU_OPTS="-nographic" QEMU_KERNEL_PARAMS="console=ttyS0" /tmp/vm/bin/disko-vm
```

With those two variables the VM has a serial console, so an `expect` script can
log in and run commands (`nixpkgs#expect`). The disk is a fresh copy each run
unless you set `tmp` in the wrapper script. virtiofs (the default store share)
cannot hibernate; use a store image instead (`virtualisation.useNixStoreImage`,
`sharedDirectories = lib.mkForce { }` in a throw-away module).

**Test the installer end to end** (this is what proves `install-host`):

1. `nix build .#installer-iso -o /tmp/inst/iso` (large; the first build is slow).
2. A blank NVMe disk (`qemu-img create -f qcow2 disk.qcow2 64G`) and UEFI
   (OVMF `OVMF_CODE.fd` read-only plus a copy of `OVMF_VARS.fd`), with
   `-nic none -nographic -cdrom <iso> -boot order=d`. Take `qemu`, `OVMF` and
   `expect` from the flake's nixpkgs
   (`nix build .#nixosConfigurations.laptop.pkgs.qemu_kvm`, `.OVMF.fd`,
   `.expect`): the ones from the registry's nixpkgs were broken once. The stick
   has a serial console already. A host with a second disk (the desktop) needs
   that disk in the VM under its real by-id name, or `install-host` refuses to
   start: `-device ich9-ahci,id=ahci -drive file=data.qcow2,if=none,id=sata1
   -device ide-hd,drive=sata1,bus=ahci.0,model="Samsung SSD 860 EVO 1TB",serial=S3Z9NBRK603979F`
   gives `ata-Samsung_SSD_860_EVO_1TB_S3Z9NBRK603979F`. After "Done", the
   system disk can be opened by hand (`cryptsetup open … --key-file=-`) to check
   `/persist/etc/data-disk.key` and `cryptsetup open --test-passphrase` the data disk.
3. Drive it with `expect`: wait for `nixos@nixos:~]$`, run
   `sudo install-host <host> [--disk /dev/nvme0n1]`, then answer in order: the
   host name, the LUKS passphrase (encrypted hosts only), `Enroll a YubiKey now`
   (`n`), `Register the new key` (`n`: there is no YubiKey in a VM), `Pause to
   restore` (`n`), wait for `Done. Reboot`. Afterwards `findmnt -R /mnt` and
   `ls /dev/mapper` must show nothing mounted and no open LUKS device.
   Write every `expect { ... }` block over several lines: a one-line
   `expect { "text" { send "x\r" } }` is taken as a single pattern and the
   answer is silently never sent (the prompt just sits there). `exp_internal 1`
   shows what it matched.
4. The installed system has no serial console. Boot the disk with
   `-display none -monitor unix:<sock>,server,nowait`, send the passphrase with
   `sendkey` through the monitor (`socat`), wait, `screendump x.ppm`, convert
   with `magick x.ppm x.png` and look at it.
5. To test failure handling use a disk too small for the swap file (12G with
   the laptop's 16G): the run must name the failed step and leave nothing
   mounted, and a second `install-host` on the same disk must work.

**How long things take** (measured here, warm cache, 4 cores; a cold cache or a
new nixpkgs makes builds several times longer). Start long jobs in the
background (`run_in_background`, or a `Monitor` with an `until` loop on the log)
and look again after the "check at" time. If nothing new appears in the log by
the "abort after" time, the run is stuck: read the log tail, kill only the
processes you started (by PID), and fix the cause instead of waiting more.

| Job | Usually takes | Check at | Abort after |
| --- | --- | --- | --- |
| `nixfmt`, `shellcheck`, `actionlint` | seconds | 30 s | 2 min |
| `nix eval` of one option | 10-20 s | 1 min | 3 min |
| `nix flake check --no-build` | 30-60 s | 2 min | 5 min |
| Build one host (only config changed) | 1-3 min | 5 min | 15 min |
| Build all four hosts in a loop | 3-8 min | 10 min | 30 min |
| `nix build .#install-host` | under 1 min (5 min the first time) | 5 min | 15 min |
| `nix build .#installer-iso` | about 10 min after a script change, 30+ min cold | 15 min | 60 min |
| `act` jobs `hosts`, `format` | about 1 min | 3 min | 10 min |
| `act` job `installer` | about 5-6 min | 10 min | 25 min |
| `act` job `build --matrix host:vps` | about 3 min | 6 min | 20 min |
| `act` job `cves --matrix host:vps` | about 4-5 min | 8 min | 25 min |
| `docker build` of the act image | under 1 min | 3 min | 10 min |
| `vmWithDisko` boot to login prompt | 1-2 min | 3 min | 8 min |
| Installer VM: boot the ISO to a shell | 40-60 s | 2 min | 5 min |
| Installer VM: one `install-host` run (offline) | 8-13 min | 15 min | 40 min |
| Installer VM: disk failure test (first run fails) | 1-3 min | 4 min | 10 min |
| Installed disk: passphrase to desktop screenshot | 3 min | 4 min | 8 min |
| `check-cves` for one host | 3-5 min | 8 min | 20 min |

Parts that stay quiet for minutes and are normal: `Creating Nix store image`,
`evaluating derivation` (a minute), disko formatting with TRIM, and
`copying path` lines during `nixos-install`. A prompt that stays on screen with
no echo of what you sent (an `expect` script that never answered it) is not
normal: stop after the "abort after" time and debug the script, not the repo.

**Reviews:** subagents are fine for a wide read-only review (split by area), but
verify every claim they make before acting on it; two of them were wrong about
`programs.xwayland` and `nvidia-drm.modeset` here, which the closure diff showed.

**Cannot be tested here:** YubiKey and FIDO2 unlock, real hardware (SMART,
hibernate resume, the laptop's NVMe), the `update` workflow job, and anything
that needs `sudo`.

**Housekeeping (a rule, not a courtesy):** when a test is finished, remove
everything that only existed for that run, in the same session, before
reporting. That is: VM disks and UEFI variable files (about 20 GB each), the
`/tmp/nix-vm.*` directories of `vmWithDisko`, built ISOs and every `-o`
result symlink you made (a symlink is a GC root that keeps the whole build
alive in the store; prefer `--no-link`), logs, `expect` scripts, helper
scripts, screenshots, scratch directories and test processes (stop only the
ones you started, by PID). Keep only what is reusable and was built once on
purpose, such as the `ubuntu-act-nix:local` image. Check `df -h /` before and
after and say in the report what was removed and how much space it freed. Use
explicit paths, e.g.
`find /tmp -maxdepth 1 -name 'nix-vm.*' -user "$USER" -exec rm -rf {} +` and
`find /tmp/<your test dir> -mindepth 1 -delete`. Run one simple command per
tool call: long compound command lines are denied by the permission rules.

## Conventions

- `.editorconfig` governs style; Nix files are formatted with `nixfmt` (RFC style). Run the formatter before committing. CI checks it, builds every host (the list comes from `nixosConfigurations`) and builds `install-host` (shellcheck).
- `stateVersion` is the release of a machine's first install and is never raised afterwards. desktop, laptop and moon are at 26.11 because they are installed fresh from that release; `vps` is a template at 26.05, so a copy of it must get the current release.
- Prefer `pkgs.stable.<pkg>` (via the overlay) when an unstable package is broken, rather than pinning inputs.
- GitHub Actions are pinned to commits (Dependabot updates them); do not switch them to `@main` or tags. Steps that need the real runner (installing Nix, freeing disk) are skipped under `act` with `if: ${{ !env.ACT }}`; `.github/act/Dockerfile` is the runner image that has Nix instead.
- Scripts and services must say what failed and leave a state that can be retried (`install-host` releases `/mnt` and the disk, `provision-server` names the step and what the repo may already hold, `claude-plugins-sync` finishes the other steps and lists the failed ones, `nix-config-checkout` notifies). Keep that when changing them.
