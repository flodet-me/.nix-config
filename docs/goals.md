# Goals

## G-1 Agent isolation: repository jail  (status: open)

Goal: "ok" — implement the agreed design of docs/agent-isolation.md and docs/adr/0001-repository-jail.md: (1) host hardening: trusted-users root on workstations, rootless Docker; (2) `jail` + `jail-push` with a NixOS VM test; (3) pasta network namespace + notification-only D-Bus proxy; (4) winvm binds.
Accept:
- `nix eval` on desktop/laptop: `nix.settings.trusted-users == ["root"]`, system Docker off, rootless Docker on with `DOCKER_HOST` set, `docker` not in flodet's groups; moon/vps keep `@wheel`.
- `checks.x86_64-linux.jail` (NixOS VM test) passes and asserts inside a jail: an unbound home path is absent, `~/brain` readable but only `inbox/` writable, the repository writable, `sudo` refused, `systemd-run --user` fails, no host session bus or `/run/user` sockets, `nix build` through the daemon works, `/dev/kvm` present when the host VM has it.
- The test asserts `jail-push` pushes the repository's commits without running a planted `core.sshCommand`, `pre-push` hook or `ext::` URL.
- The test asserts inside a jail: a TCP listener on the host's 127.0.0.1 is unreachable, outbound TCP to another host works, `org.freedesktop.Notifications` is reachable through the proxy and any other bus name is not.
- The test asserts winvm binds: base images read-only, `state/vms` and `runs` writable and separate per repository.
- Gate green; docs (agent-isolation.md, testing.md, a jail how-to) match the code.
Not in scope: egress allowlist, Claude Code built-in sandbox settings, microVM profile, containers inside a jail, GUI IDEs inside a jail, an agent inside the Windows VM, `nixos-rebuild switch`.
Assumptions:
- The user's "yes" to Docker means rootless is fine. Old system Docker images/volumes stay in /persist/var/lib/docker, unused.
- `jail` is a home-manager module on the workstations (desktop.nix), the repo is bound at its own absolute path, HOME stays /home/flodet inside.
- A real Windows boot through winvm in a jail is checked by hand after the switch, not in the VM test.

| Item | What | Status | Commit |
|---|---|---|---|
| I1 host-hardening | trusted-users root on workstations, rootless Docker, docs | done | 067e623 |
| I2 jail | `jail` / `jail-push`, tmux-shared jail per repo, VM test `checks.jail`, docs | open | |
| I3 jail-net | pasta netns (no host loopback), xdg-dbus-proxy for notifications, test | open | |
| I4 jail-winvm | winvm binds and `winvm` wrapper inside the jail, test | open | |
