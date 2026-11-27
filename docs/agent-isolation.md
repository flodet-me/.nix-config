# Agent isolation (concept)

Status: proposal, not implemented. Findings verified on `desktop` on
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
  essentially root).
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
| B. **bubblewrap jail, same uid** | mount namespace: only bound paths exist; `no_new_privs` makes `sudo` and other setuid useless; own PID namespace | yes, verified | one Nix-built wrapper; files keep your ownership |
| C. Separate Unix user per agent | kernel file permissions | yes (`/dev/kvm` is 0666) | shared group/ACLs on every repo, `safe.directory`, two owners per file |
| D. MicroVM per project (microvm.nix) | own kernel | nested KVM only, slow for Windows | store sharing via virtiofs, more RAM, per-VM networking |

## Recommendation: B plus host hardening, A as an inner layer

1. **Close the root paths** (useful on its own, independent of agents):
   `trusted-users = [ "root" ]` (substituters are already system-wide in
   `nix.nix`); Docker rootless instead of the `docker` group; agents never get
   the libvirt system socket (virt-manager stays a human tool). `sudo` stays
   for you, the jail kills it for agents through `no_new_privs`.
2. **`agent-jail` wrapper** (home-manager module, `writeShellApplication`
   around `bwrap`): `agent-jail claude` / `agent-jail codex` in a repository.
   - `--unshare-all --share-net --die-with-parent --new-session`, `--tmpfs
     /home`, own `/proc`, `/dev`, `/tmp`.
   - Read-only: `/nix`, `/etc`, `/run/current-system`, `~/brain`; read-write:
     the repository, `~/brain/inbox`, the Nix daemon socket, `/dev/kvm`, the
     caches that are only caches (`~/.cache/nix`, `nuget`, `npm`, `cargo`).
   - Read-only inside the writable repository: `.git/hooks`, `.git/config`,
     `.envrc`, `.nvim.lua`, `.claude/settings*.json` (change them yourself,
     outside), so nothing the agent writes runs unjailed later.
   - `~/.claude`, `~/.claude.json`, `~/.codex` read-write for login, sessions
     and plugins, but `~/.claude/settings.json`, `rules/`, `skills/`, `agents/`
     read-only (Nix owns them anyway; a hook written there would run in your
     next unjailed session).
   - No `/run/user/1000`, no session bus. Desktop notifications through
     `xdg-dbus-proxy --talk=org.freedesktop.Notifications` only.
   - Smoke test run by hand on 2026-11-27 with exactly these binds:
     `~/Nextcloud` absent, `~/brain` readable, `KVM_GET_API_VERSION` 12 on
     `/dev/kvm`, a `nix build` through the daemon worked, DNS worked,
     `/run/user/1000`, `systemd-run --user`, the Docker and libvirt sockets
     unreachable.
3. **Network in its own namespace** with `pasta` (as rootless Podman does):
   outbound internet works, but the host's localhost services and abstract
   Unix sockets (Xwayland, some D-Bus) are no longer shared, which plain
   `--share-net` does. Optional later: an egress allowlist (model APIs, Nix
   caches, package registries) through a filtering proxy.
4. **Claude Code's sandbox inside the jail** for finer per-command network
   and write rules, if wanted; the jail stays the boundary.
5. **Untrusted third-party code**: profile D (microVM) for that repository
   only.

Checks for the implementation: a NixOS VM test that runs the wrapper as the
user and asserts the table above (hidden paths absent, `sudo` refused,
`/dev/kvm` opens, `nix build` works).

## VMs and Windows development

- winvm (`~/Projects/windows-vm`) is plain QEMU/KVM without libvirt or root;
  its files live in its directory. Inside the jail it needs only `/dev/kvm`,
  its directory and user-mode networking (passt/slirp), all unprivileged.
  Bridged or tap networking needs root: not for agents.
- **Building for Windows on Linux, testing in the VM** (default): .NET
  publishes `-r win-x64`; WinForms/WPF build with `EnableWindowsTargeting=true`
  but run only on Windows; Rust targets `x86_64-pc-windows-gnu` with a MinGW
  cross toolchain in the dev shell. The agent runs the result with
  `winvm run ./app.exe` from inside the jail and reads exit code, output and
  crash analysis.
- **Agent inside the Windows VM** (when a toolchain exists only on Windows,
  e.g. Visual Studio-only projects): the VM is the sandbox. It gets the repo
  by git over SSH or a share of that one directory, never the host home, and
  its own Claude/Codex login.
- Rider, VS Code and virt-manager stay unjailed: they are you.

## Open questions

1. One repository per session, or all of `~/Projects` for cross-repo work?
2. `~/.claude/projects/` holds transcripts of every project: is one shared
   Claude home acceptable, or one `CLAUDE_CONFIG_DIR` per repository (one
   login each)?
3. Do you use Docker through the group, or is rootless Docker/Podman fine?
4. Windows: building on Linux and testing in winvm, an agent inside the VM,
   or both?
