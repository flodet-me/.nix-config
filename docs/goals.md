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
- User, 2026-11-27, asked to see websites served from a jail: added I3b, host→jail TCP forwards on 127.0.0.1 chosen at jail start (pasta `-t`), never jail→host.
- User, 2026-11-27: a running jail may keep a stale Claude login after a refresh outside; accepted for now (restart the jail). After G-1 is done, re-run the Claude Code setup audit and re-evaluate its quick wins (deny rules for ~/Nextcloud, ~/Documents, keyring, key files).

| Item | What | Status | Commit |
|---|---|---|---|
| I1 host-hardening | trusted-users root on workstations, rootless Docker, docs | done | 067e623 |
| I2 jail | `jail` / `jail-push`, tmux-shared jail per repo, VM test `checks.jail`, docs | done | 015d25b |
| I3 jail-net | pasta netns (no host loopback), xdg-dbus-proxy for notifications, test | open | |
| I3b jail-ports | `jail --port N`: host 127.0.0.1:N forwarded into the jail (host→jail only), test, docs | open | |
| I4 jail-winvm | winvm binds and `winvm` wrapper inside the jail, test | open | |

## G-2 LLM token tools  (status: done)

Goal: "do it and keep ownership in nix" — add ccusage, ast-grep and rtk declaratively, with the rtk Claude Code hook on trial, compared via `rtk gain` after a week.
Accept:
- ccusage, ast-grep, rtk on the workstation user PATH from home-manager (`nix eval` of home.packages / built home-files).
- The rtk rewrite hook is a PreToolUse Bash hook in the Nix-owned `hooks` of `~/.claude/settings.json`; nothing depends on `rtk init` writing files (no `rtk init -g` in activation or sync).
- rtk's config (telemetry off, recovery mode) is a Nix-made file; its instructions for the agent come from Nix-managed instructions, not an `@RTK.md` written at runtime.
- A test shows the hook rewrites `git status` to the rtk form and leaves a command rtk does not know unchanged; Claude Code's deny rules still block a denied command after rewriting (or the doc states the verified behaviour).
- One switch turns the trial off; docs/claude-code.md says how to read `rtk gain` / `ccusage` and how to turn rtk off.
- Gate green.
Not in scope: rtk for Codex, rtk llm-proxy, rtk plugins/TOML filters, project-local rtk filters, extra LSP plugins (rust-analyzer, TypeScript, C# LSP plugins are already enabled).
Assumptions:
- Trial = enabled by default via a home-manager option that is easy to flip; the one-week review is a reminder in the docs, not automation.
- rtk's history lives in its default data dir; inside a jail it is per jail home (G-1), accepted.

| Item | What | Status | Commit |
|---|---|---|---|
| I1 token-tools | ccusage, ast-grep, rtk + Nix-owned rtk hook/config/instructions, test, docs | done | f052e8a |
