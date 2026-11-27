# 0001: One bubblewrap jail per repository for agents and your own tools

Date: 2026-11-27. Status: accepted; host hardening and the jail implemented
([jail.md](../jail.md)), network namespace and D-Bus proxy implemented, per-repository `.jail`
implemented, winvm binds open.

## Context

Agents (Claude Code, Codex) and the code they run work as `flodet` and can
read everything that user can: `~/Nextcloud`, keyring, gpg-agent, other
repositories. Permission rules match command text, Codex's `read-only` mode
still reads the whole disk, and `docker`, `libvirtd`, `wheel` and nix
`trusted-users` are ways to root. Agent-written files (`.envrc`, `flake.nix`
shellHooks, `.nvim.lua`, git hooks) run later in your unjailed tools. Agents
must still use the brain, Nix, the network and KVM (winvm, Windows targets).
Details and verification: [agent-isolation.md](../agent-isolation.md).

## Options

1. Claude Code's built-in sandbox only: Bash only, not Codex or other tools.
2. bubblewrap jail as the same user, one per repository.
3. A separate Unix user per agent: ownership and ACLs on every repository.
4. A microVM per repository: strongest, nested KVM for Windows VMs.

## Decision

Option 2, with your shell, Neovim, direnv and git for that repository inside
the same jail, one repository per jail, a shared `~/.claude` login, rootless
Docker and `trusted-users = root` on workstations. Pushes leave through a
mirror outside the jail. Option 1 may run inside as an extra layer; option 4
is kept for untrusted third-party code.

## Consequences

- Nothing written in a jail runs outside it; reviewing agent diffs is about
  quality, not about host safety.
- Opening a repository means `jail <repo>`; GUI IDEs on jailed repositories
  run inside with the Wayland socket only.
- No gpg-agent or SSH keys in the jail: pushing is `jail-push`, outside.
- `act` and other Docker users move to rootless Docker; containers inside a
  jail are still open.
- What a repository needs beyond the defaults (ports from host `127.0.0.1`
  into the jail, extra `ro`/`rw` folders, later winvm) lives in its own
  `.jail`, not in home-manager, since `jail` is repository-agnostic. Jailed
  code can write that file, so only a copy approved on a terminal applies,
  stored outside the jail; ports never go from the jail to the host.
- 2026-11-27: the jail moved from a home-manager module to its own package,
  `pkgs/jail` (scripts in `.sh` files), installed system-wide on the
  workstations; behavior unchanged.
- The Nix daemon is shared: builds are sandboxed by Nix, but an agent can
  fill the store and use your binary caches.

Decided by: user (scope: one repository per jail, shared Claude login,
rootless Docker, own tools inside the jail) and agent (mechanism, Windows
approach).
