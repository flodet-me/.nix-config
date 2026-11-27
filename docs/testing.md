# Testing and VM runs

Non-destructive checks, closure diffs, `vmWithDisko`, and end-to-end installer ISO testing. Everything here runs without `sudo` and without the YubiKey. New files must be known to git (`git add -N <file>`) or flakes will not see them.

Do not `nixos-rebuild switch` the machine you are on to test: build instead.

## Quick checks (after any Nix change)

```sh
nixfmt $(git ls-files -co --exclude-standard '*.nix')   # not `nix fmt`: it hung once
nix flake check --no-build                              # evaluates packages, checks, hosts
nix build --no-link .#checks.x86_64-linux.formatting .#checks.x86_64-linux.sops-encrypted
for h in laptop desktop moon vps; do                    # all four must build
  nix build --no-link .#nixosConfigurations.$h.config.system.build.toplevel
done
nix eval .#nixosConfigurations.<host>.config.<option>                              # inspect a system option
nix eval .#nixosConfigurations.laptop.config.home-manager.users.flodet.<option>    # ... or a home option
deadnix -l .                                            # unused arguments (`-e` edits: rebuild after, callers may pass them)
statix check .                                          # Nix anti-patterns
```

## Prove a refactor changed nothing

Before editing, record:

```sh
nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath
```

for each host. Afterwards `nix build "<old drv>^out"` and the new toplevel, then `nix store diff-closures <old> <new>` (packages) and `diff -rq <old>/ <new>/` (generated files such as `etc/`, `kernel-params`). Only intended differences may remain; `nix-diff` is too verbose to read.

## Scripts and workflows

```sh
nix build --no-link .#install-host            # also runs shellcheck on the installer script
shellcheck -S warning scripts/<name>/<name>.sh
actionlint .github/workflows/*.yml
act -W .github/workflows/nix.yml -j format    # run a CI job in Docker (one-time image build: docker build -t ubuntu-act-nix:local .github/act)
act -W .github/workflows/nix.yml -j build --matrix host:vps
act -W .github/workflows/security.yml -j cves --matrix host:vps   # fails when CVEs are found: that is its job
```

Docker is rootless on the workstations (user service `docker`, `DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock` set at login, data in `~/.cache/docker`, outside the `/home` snapshots). It has its own image store, so build the act image once more after switching from the old system daemon; `.actrc` needs no socket path.

`act` works for `hosts`, `format`, `installer`, `build` and `cves`; the `update` job needs a real token and cannot be tried. If a step fails only under `act`, check `if: ${{ !env.ACT }}` first.

## Run a host in a VM

Needs `/dev/kvm`; LUKS passphrase `disko`, login password `123456789`:

```sh
nix build .#nixosConfigurations.<host>.config.system.build.vmWithDisko -o /tmp/vm
cd "$(mktemp -d)"   # never start it inside the repo, see below
QEMU_OPTS="-nographic" QEMU_KERNEL_PARAMS="console=ttyS0" /tmp/vm/bin/disko-vm
```

The VM writes its UEFI variable store, `<host>-efi-vars.fd` (about 0.5 MB), into the **current directory**, so start it from a scratch directory, never from the repo (a started-in-background `expect` job inherits the directory you were in). `.gitignore` hides such files as a safety net, but delete them with the rest of the test data.

With those two variables the VM has a serial console, so an `expect` script can log in and run commands (`nixpkgs#expect`). The disk is a fresh copy each run unless you set `tmp` in the wrapper script. `virtiofs` (the default store share) cannot hibernate; use a store image instead (`virtualisation.useNixStoreImage`, `sharedDirectories = lib.mkForce { }` in a throw-away module).

## Test the installer end to end

This is what proves `install-host`:

1. `nix build .#installer-iso -o /tmp/inst/iso` (large; the first build is slow).
2. A blank NVMe disk (`qemu-img create -f qcow2 disk.qcow2 64G`) and UEFI (OVMF `OVMF_CODE.fd` read-only plus a copy of `OVMF_VARS.fd`), with `-nic none -nographic -cdrom <iso> -boot order=d`. Take `qemu`, `OVMF` and `expect` from the flake's nixpkgs (`nix build .#nixosConfigurations.laptop.pkgs.qemu_kvm`, `.OVMF.fd`, `.expect`): the ones from the registry's nixpkgs were broken once. The stick has a serial console already. A host with a second disk (the desktop) needs that disk in the VM under its real by-id name, or `install-host` refuses to start:
   `-device ich9-ahci,id=ahci -drive file=data.qcow2,if=none,id=sata1 -device ide-hd,drive=sata1,bus=ahci.0,model="Samsung SSD 860 EVO 1TB",serial=S3Z9NBRK603979F`
   gives `ata-Samsung_SSD_860_EVO_1TB_S3Z9NBRK603979F`. After "Done", the system disk can be opened by hand (`cryptsetup open … --key-file=-`) to check `/persist/etc/data-disk.key` and `cryptsetup open --test-passphrase` the data disk.
3. Drive it with `expect`: wait for `nixos@nixos:~]$`, run `sudo install-host <host> [--disk /dev/nvme0n1]`, then answer in order: the host name, the LUKS passphrase (encrypted hosts only), `Register the new key` (`n`: there is no YubiKey in a VM), `Pause to restore` (`n`), wait for `Done. Reboot`. Afterwards `findmnt -R /mnt` and `ls /dev/mapper` must show nothing mounted and no open LUKS device.
   Write every `expect { ... }` block over several lines: a one-line `expect { "text" { send "x\r" } }` is taken as a single pattern and the answer is silently never sent (the prompt just sits there). `exp_internal 1` shows what it matched.
4. The installed system has no serial console. Boot the disk with `-display none -monitor unix:<sock>,server,nowait`, send the passphrase with `sendkey` through the monitor (`socat`), wait, `screendump x.ppm`, convert with `magick x.ppm x.png` and look at it.
5. To test failure handling use a disk too small for the swap file (12G with the laptop's 16G): the run must name the failed step and leave nothing mounted, and a second `install-host` on the same disk must work.

## Typical timings

Measured locally with a warm cache and 4 cores; a cold cache or a new nixpkgs makes builds several times longer. Start long jobs in the background and check at the times below; if nothing new appears in the log by "Abort after", read the log tail, kill only the processes you started (by PID), and fix the cause.

| Job | Usually takes | Check at | Abort after |
| --- | --- | --- | --- |
| `nixfmt`, `shellcheck`, `actionlint` | seconds | 30 s | 2 min |
| `nix eval` of one option | 10-20 s | 1 min | 3 min |
| `nix flake check --no-build` | 30-60 s | 2 min | 5 min |
| Build one host (only config changed) | 1-3 min | 5 min | 15 min |
| Build all four hosts in a loop | 3-8 min | 10 min | 30 min |
| `nix build .#install-host` | under 1 min (5 min first time) | 5 min | 15 min |
| `nix build .#installer-iso` | ~10 min after script change, 30+ min cold | 15 min | 60 min |
| `act` jobs `hosts`, `format` | ~1 min | 3 min | 10 min |
| `act` job `installer` | ~5-6 min | 10 min | 25 min |
| `act` job `build --matrix host:vps` | ~3 min | 6 min | 20 min |
| `act` job `cves --matrix host:vps` | ~4-5 min | 8 min | 25 min |
| `docker build` of the act image | under 1 min | 3 min | 10 min |
| `vmWithDisko` boot to login prompt | 1-2 min | 3 min | 8 min |
| Installer VM: boot the ISO to a shell | 40-60 s | 2 min | 5 min |
| Installer VM: one `install-host` run (offline) | 8-13 min | 15 min | 40 min |
| Installer VM: disk failure test (first run fails) | 1-3 min | 4 min | 10 min |
| Installed disk: passphrase to desktop screenshot | 3 min | 4 min | 8 min |
| `check-cves` for one host | 3-5 min | 8 min | 20 min |

Parts that stay quiet for minutes and are normal: `Creating Nix store image`, `evaluating derivation` (~1 min), `disko` formatting with TRIM, and `copying path` lines during `nixos-install`. A prompt staying on screen with no echo of what you sent means the `expect` script never matched it: abort and debug the script.

## Cannot be tested in automation

Anything that needs the YubiKey (signing, SSH, sops registration), real hardware (SMART, hibernate resume, the laptop's NVMe), the `update` workflow job, and anything that needs `sudo`.

## Housekeeping (mandatory)

When a test is finished, remove everything that only existed for that run in the same session before reporting:
- VM disks and UEFI variable files (~20 GB each), `/tmp/nix-vm.*` directories from `vmWithDisko`
- Built ISOs and every `-o` result symlink (a symlink is a GC root; prefer `--no-link`)
- Logs, `expect` scripts, helper scripts, screenshots, scratch directories, and test processes you started (by PID)

Keep only reusable artifacts built once on purpose (such as `ubuntu-act-nix:local`). Check `df -h /` before and after, and report what was removed and how much space it freed. Use explicit paths (`find /tmp -maxdepth 1 -name 'nix-vm.*' -user "$USER" -exec rm -rf {} +` and `find /tmp/<test-dir> -mindepth 1 -delete`).
