# Agent isolation

Status: design agreed, not implemented. Findings verified on `desktop` on
2026-11-27.

## Goal

An agent session (Claude Code, Codex, and everything they start: builds,
tests, `build.rs`, npm/MSBuild scripts, language servers) works on one
repository and sees only what that needs:

| Allowed | Hidden |
| --- | --- |
| the repository (read-write) | `~/Nextcloud`, `~/Documents`, `~/Pictures`, ... |
| `~/brain` (read; `inbox/` writable) | other repositories |
| `/nix/store`, the Nix daemon, its own caches | `~/.ssh`, `~/.gnupg`, gpg-agent, YubiKey |
| its own login and config (`~/.claude`, `~/.codex`) | GNOME keyring / Secret Service, browser profiles |
| network (model API, caches, registries) | session D-Bus, `systemd --user`, Nextcloud client |
| `/dev/kvm`: QEMU VMs incl. Windows (winvm) | `/run/secrets`, Docker and libvirt system sockets |

## Why today's setup is not a boundary

- Claude Code's deny rules match command text: another spelling of the same
  read passes ([claude-code.md](claude-code.md), "Permissions"). Its `sandbox`
  setting is unset.
- Codex's `read-only` sandbox forbids writes, not reads: it can read the whole
  disk, `~/Nextcloud` included.
- Ways to root that need no sandbox escape, all open to an agent running as
  `flodet`: the `docker` group (mount `/` into a container), the `libvirtd`
  group (a VM with the host disk attached), `wheel` with the published
  password `123456789` (`sudo` under any other spelling), and
  `trusted-users = @wheel` in `nix.nix` (the Nix manual calls a trusted user
  essentially root). The `docker` group and `trusted-users` are closed on the
  workstations since design step 1.
- `/run/user/1000` and the session bus reach gpg-agent (signing, SSH to the
  servers, sops with the YubiKey plugged in), the keyring
  (`org.freedesktop.secrets`), the Nextcloud client, gvfs mounts, and
  `systemd-run --user`, which starts a process outside any sandbox.
- Files the agent may write run later outside its session, as you: `.envrc`
  (direnv), `.nvim.lua` (after `:trust`), `.git/hooks/*` and `.git/config`
  (`core.hooksPath`, `core.fsmonitor`), `.claude/settings.json` hooks,
  `~/.claude/settings.json`, shell rc files.

## Options

| | Boundary | VMs (`/dev/kvm`) | Effort, friction |
| --- | --- | --- | --- |
| A. Claude Code's built-in sandbox (`sandbox.*`, bwrap + socat) | Bash and its children only; not the Read/Edit/Write tools, hooks, MCP or LSP servers, nor Codex run on its own | `/dev/kvm` must be allowed | settings only |
| B. **bubblewrap jail, same uid** | mount namespace: only bound paths exist; `no_new_privs` makes `sudo` and other setuid useless; own PID namespace | yes (`/dev/kvm` opens) | one Nix-built wrapper; files keep your ownership |
| C. Separate Unix user per agent | kernel file permissions | yes (`/dev/kvm` is 0666) | shared group/ACLs on every repo, `safe.directory`, two owners per file |
| D. MicroVM per project (microvm.nix) | own kernel | nested KVM only, slow for Windows | store sharing via virtiofs, more RAM, per-VM networking |

## Design: one jail per repository, you work inside it too

Decided 2026-11-27 ([ADR 0001](adr/0001-repository-jail.md)): option B,
plus host hardening, with option A as an optional inner layer. One
repository per jail. Your shell, Neovim, direnv and git for that repository
run in the same jail as the agents, so nothing written there is ever executed
outside it.

1. **Close the root paths** (useful on its own, independent of agents).
   Implemented for `trusted-users` and Docker (`workstation.nix` asserts both):
   - `trusted-users = [ "root" ]` on the workstations only. Substituters are
     already system-wide in `nix.nix`; a flake's `nixConfig`
     `extra-substituters` is no longer accepted for `flodet` there (add a
     cache to `nix.nix` instead). The servers keep `@wheel`
     (`server/hardening.nix`), because `nixos-rebuild --target-host` copies
     unsigned closures as the SSH user.
   - Rootless Docker instead of the `docker` group (`act` then talks to
     `$XDG_RUNTIME_DIR/docker.sock`, `DOCKER_HOST` is set at login). Images
     and volumes of the system daemon stay in `/var/lib/docker` and are not
     seen by the rootless one (data in `~/.local/share/docker`).
   - Agents never get the libvirt system socket; virt-manager stays outside.
   - `sudo` stays for you; inside the jail `no_new_privs` disables it.
2. **`jail <repo>`** (home-manager module, `writeShellApplication` around
   `bwrap`) opens a shell in the jail of that repository. The first call
   starts a tmux server inside the jail, later calls attach to it, so every
   terminal of one repository shares one jail (processes, network, VMs).
   `claude`, `codex`, `nvim` are started from that shell.
   - `--unshare-all --die-with-parent --new-session`, `--tmpfs /home`, own
     `/proc`, `/dev`, `/tmp`.
   - Read-only: `/nix`, `/etc`, `/run/current-system`, `~/brain`, and the
     Nix-made dotfiles the shell and editor need (`~/.zshrc`,
     `~/.config/{nvim,git,direnv}`, `~/.local/share/nvim/site`).
   - Read-write: the repository, `~/brain/inbox`, the Nix daemon socket,
     `/dev/kvm`, a per-repository jail home (`~/.local/share/jails/<repo>`:
     shell history, nvim state and `:trust` list, direnv allow list), the
     shared caches (`~/.cache/nix`, `nuget`, `npm`, `cargo`).
   - `~/.claude`, `~/.claude.json`, `~/.codex` read-write and shared by all
     jails (one login; transcripts of all repositories in one place, accepted),
     except `~/.claude/settings.json`, `rules/`, `skills/`, `agents/`
     read-only: a hook written there would run in every other jail.
   - No `/run/user/1000`, no session bus, no gpg-agent, no SSH keys.
     Desktop notifications through
     `xdg-dbus-proxy --talk=org.freedesktop.Notifications` only.
   - **Push** stays outside and must not read the repository's config
     (`core.sshCommand`, `url.*.insteadOf`, hooks run code):
     `jail-push <repo>` fetches into a mirror the jail cannot write
     (`~/.local/share/jails/<repo>.git`) and pushes from there. To verify:
     that `git fetch` from a local path runs nothing from the source
     repository's config.
   - GUI IDEs (Rider, VS Code) on a jailed repository: only inside the jail
     with the Wayland socket bound (Rider natively on Wayland; never the X11
     socket, which lets any client read all input). Otherwise use nvim.
3. **Network in its own namespace** with `pasta` (as rootless Podman does):
   outbound internet works, but the host's localhost services and abstract
   Unix sockets (Xwayland, some D-Bus) are not shared, which `--share-net`
   does. winvm's port forwards on 127.0.0.1 then stay inside the jail.
   Later, if wanted: an egress allowlist (model APIs, Nix caches, registries)
   through a filtering proxy.
4. **Claude Code's sandbox inside the jail** for finer per-command rules, if
   wanted; the jail stays the boundary.
5. **Untrusted third-party code**: option D (microVM) for that repository.

Tested by hand on 2026-11-27 with a subset of these binds (`/nix`, `/etc`,
daemon socket, `/dev/kvm`, `~/brain` read-only, one repository,
`--share-net`): `~/Nextcloud` absent, `~/brain` readable,
`KVM_GET_API_VERSION` 12 on `/dev/kvm`, `nix build` through the daemon and DNS
worked; `/run/user/1000`, `systemd-run --user`, the Docker and libvirt sockets
unreachable. Also tested: read-only binds of `.git/hooks` inside the writable
repository do not hold (`mv .git .git.x && git init`), which is why your own
tools move into the jail rather than the agent getting read-only islands.
Not tested yet: `claude`, `codex`, zsh and nvim inside the jail, a real winvm
boot, `pasta`, `xdg-dbus-proxy`, the push mirror.

Implementation checks: a NixOS VM test that runs `jail` as the user and
asserts the table above (hidden paths absent, `sudo` refused, `/dev/kvm`
opens, `nix build` works, `jail-push` ignores a planted `core.sshCommand`).

## VMs and Windows development

- winvm (`~/Projects/windows-vm`) is plain QEMU/KVM without libvirt or root.
  In a jail: its code and `state/images/` (the ~20 GB base images, bound at
  the same path so the qcow2 backing paths resolve) read-only, `state/vms/`
  and `runs/` from the jail home read-write. So every repository has its own
  VMs on shared base images, and `winvm commit` or `build` (changing a base
  image) happen outside, by you. User-mode networking (passt/slirp) is
  unprivileged; bridged or tap networking needs root: not in a jail.
- **Default: build on Linux, test in winvm.** .NET publishes `-r win-x64`;
  WinForms/WPF build with `EnableWindowsTargeting=true` and run only in the
  VM; Rust targets `x86_64-pc-windows-gnu` with a MinGW cross toolchain from
  the dev shell. The agent runs the result with `winvm run --dir build/
  bin/app.exe` and reads exit code, output and the WinDbg analysis. This covers
  most .NET and Rust work, keeps the agent on Linux under the jail, and a
  reset VM is a second away.
- **Only when a toolchain exists only on Windows** (MSVC C++, Visual
  Studio-only project types, MSIX packaging and signing): the agent runs
  inside a winvm VM, which is then the sandbox. It gets the repository by git
  over SSH from the jail, never a share of the host home, has its own
  Claude/Codex login, and the VM is reset to a snapshot afterwards.

## Open

- Containers for jailed repositories (`act`, test databases): rootless
  Podman inside the jail needs nested user namespaces; to test. The rootless
  Docker socket must not be bound into a jail: its containers can mount
  every file you own.
