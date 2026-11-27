# Goals

## G-1 Agent isolation: repository jail  (status: done)

Goal: "ok" — implement the agreed design of docs/agent-isolation.md and docs/adr/0001-repository-jail.md: (1) host hardening: trusted-users root on workstations, rootless Docker; (2) `jail` + `jail-push` with a NixOS VM test; (3) pasta network namespace + notification-only D-Bus proxy; (4) winvm binds.
Accept:
- `nix eval` on desktop/laptop: `nix.settings.trusted-users == ["root"]`, system Docker off, rootless Docker on with `DOCKER_HOST` set, `docker` not in flodet's groups; moon/vps keep `@wheel`.
- `checks.x86_64-linux.jail` (NixOS VM test) passes and asserts inside a jail: an unbound home path is absent, `~/brain` readable but only `inbox/` writable, the repository writable, `sudo` refused, `systemd-run --user` fails, no host session bus (only the Notifications proxy) or other `/run/user` sockets, `nix build` through the daemon works, `/dev/kvm` present when the host VM has it.
- The test asserts `jail-push` pushes the repository's commits without running a planted `core.sshCommand`, `pre-push` hook or `ext::` URL.
- The test asserts inside a jail: a TCP listener on the host's 127.0.0.1 is unreachable, outbound TCP to another host works, `org.freedesktop.Notifications` is reachable through the proxy and any other bus name is not.
- Gate green; docs (agent-isolation.md, testing.md, a jail how-to) match the code.
Not in scope: winvm binds (user, 2026-11-27: skip for now), egress allowlist, Claude Code built-in sandbox settings, microVM profile, containers inside a jail, GUI IDEs inside a jail, an agent inside the Windows VM, `nixos-rebuild switch`.
Assumptions:
- The user's "yes" to Docker means rootless is fine. Old system Docker images/volumes stay in /persist/var/lib/docker, unused.
- `jail` is a home-manager module on the workstations (desktop.nix), the repo is bound at its own absolute path, HOME stays /home/flodet inside.
- A real Windows boot through winvm in a jail is checked by hand after the switch, not in the VM test.
- User, 2026-11-27: websites served from a jail must be viewable, and custom directories and features are defined per repository; the `jail` tool itself stays in home-manager. Hence I3b: a `.jail` file in the repository, read host-side without links like `.git/config`; jailed code can edit it, so `jail` uses only a copy the user approved on a terminal (diff shown, typed `yes`), stored under `~/.local/share/jails/<name>/`; ports only host→jail on 127.0.0.1, never jail→host; directories read-only unless marked writable.
- User, 2026-11-27: a running jail may keep a stale Claude login after a refresh outside; accepted for now (restart the jail). After G-1 is done, re-run the Claude Code setup audit and re-evaluate its quick wins (deny rules for ~/Nextcloud, ~/Documents, keyring, key files).

| Item | What | Status | Commit |
|---|---|---|---|
| I1 host-hardening | trusted-users root on workstations, rootless Docker, docs | done | 067e623 |
| I2 jail | `jail` / `jail-push`, tmux-shared jail per repo, VM test `checks.jail`, docs | done | 015d25b |
| I3 jail-net | pasta netns (no host loopback), xdg-dbus-proxy for notifications, test | done | c39dcb7 |
| I3b jail-config | per-repository `.jail` file read by `jail` on start: features (ports forwarded host 127.0.0.1→jail; I4 adds winvm) and extra read-only / read-write directories, approved on the host like `direnv allow` and used from the approved copy, test, docs | done | d44f42a |
| I4 jail-winvm | winvm binds and `winvm` wrapper inside the jail, test | skipped (user) | |

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

## G-3 Jail for bare-repository worktree layouts  (status: done)

Goal: "jail is not working in a worktree environment, like the command-and-control repo in Projects."
Accept:
- `jail DIR` and `jail DIR -- CMD` work for a container layout (`<root>/.bare` bare repository, `<root>/.git` a file `gitdir: ./.bare`, worktrees such as `<root>/main` with `.git` files pointing into `.bare/worktrees/`), from the container and from any worktree in it; all worktrees of one container share one jail; git works inside in every worktree.
- `jail-push DIR` pushes the branch checked out in the worktree DIR is in (the bare HEAD when DIR is the container), through the same mirror and sandboxed upload-pack; the URL is recorded at the first `jail` start as for normal repositories.
- Host side reads only data from the jail-writable `.git` files: `<root>/.git` must be a regular file `gitdir: ./<name>` naming a real (non-link) bare repository directory directly in `<root>`; a worktree's `.git` must point to `<root>/<name>/worktrees/<n>` and its HEAD is read without links; anything else is refused or falls back to "name the branch".
- `checks.x86_64-linux.jail` covers the layout and the refused variants (gitdir to another repository, absolute or `..` gitdir, a link instead of the bare directory or of `worktrees`, a worktree `.git` pointing elsewhere); normal repositories unchanged; Gate green; docs/jail.md updated.
Not in scope: linked worktrees outside the repository or container directory, submodules with separate git dirs, other layouts (`GIT_DIR` set elsewhere).
Assumptions:
- The container directory is the jail root (it holds `.bare`, the worktrees and other files such as `.claude/`), so the jail's name and mirror belong to the container.

| Item | What | Status | Commit |
|---|---|---|---|
| I1 bare-layout | container root detection, jail-push branch per worktree, safe gitfile reads, test, docs | done | ed33928 |

## G-4 Review before switch  (status: open)

Goal: (from the agentic-OS proposal, item 2: "do it but not with yubikey requirement for sudo") show what changed since the running system before it is switched, so an agent changing its own rules in this repository is seen.
Accept:
- Every host records the flake revision it was built from: `nixos-version --configuration-revision` on a built system prints the commit (`self.rev`, or `self.dirtyRev` for a dirty tree).
- A dev-shell script `switch-review [REV]` (default: the running system's revision, `-dirty` stripped) prints, for this repository: the commits `REV..HEAD`, uncommitted changes, and the full diff of security-relevant paths (Claude Code config, jail, users, nix settings, server hardening, impermanence, sops/keys, flake inputs, overlays, pkgs, scripts) plus the changed lines elsewhere that match security keywords (sudo, polkit, groups, trusted users, wrappers, permissions, hooks); an unknown or missing revision is said plainly with a fallback.
- It runs git on the repository safely (the repository may have been written from a jail): no pager, no external diff or textconv, no fsmonitor, no hooks, no includes of attacker config.
- `update` shows the review, then asks before `nh os switch` runs; the review alone never switches.
- `checks.x86_64-linux.scripts` builds it (shellcheck); a test shows a change to a security path and a keyword line appear and an unrelated change does not; docs (docs/claude-code.md or docs/security-updates.md, AGENTS.md command list) updated; Gate green.
Not in scope: YubiKey for sudo (user: no), blocking a switch automatically, signing commits.
Assumptions:
- Informational, the human decides: the review lists, it never fails a switch.

| Item | What | Status | Commit |
|---|---|---|---|
| I1 switch-review | configurationRevision, switch-review script, update alias, test, docs | open | |
