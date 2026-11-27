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
- Every host records the revision it was built from (`nixos-version --configuration-revision`); workstations also keep the flake source in their closure (`/run/current-system/flake-source` -> `self`); servers don't (they would carry the other hosts' encrypted secrets).
- `update` builds the toplevel once, shows `switch-review` of that build's `flake-source` against the running system's (full diff of every changed file outside `docs/`, `docs/` as names only), then asks, and switches exactly the reviewed store path; a failed review never switches.
- The review cannot be forged or emptied by the tree's content: no git on the repository, own file listing (any name), non-regular files and type changes flagged with their targets, text diff even with NUL, control characters shown visibly; tools by absolute path (direnv's dev shell comes first on PATH in the repository).
- `checks.x86_64-linux.scripts` builds and tests it (names with space/newline, symlink, type change, NUL, CR/ESC); docs (docs/agent-isolation.md, AGENTS.md) updated; Gate green.
Not in scope: YubiKey for sudo (user: no), signing commits, a commit log (git on the repository), reviewing `--target-host` deploys.
Assumptions:
- The human decides; the review informs and the switch waits for the answer.
- Reviewer round 1 (2026-11-27) found the path list and keyword scan too narrow and the diff parsing forgeable: replaced by a full diff outside `docs/`.

| Item | What | Status | Commit |
|---|---|---|---|
| I1 switch-review | configurationRevision, flake-source in the closure, switch-review script, update alias, check, docs | blocked: review round 2 — new-only files not listed (find on a symlinked root); the build itself writes the flake-source the review trusts. Retry: prefetch the tree, build exactly that store path, review it | |

## G-5 Review fixes: small and medium changes  (status: open)

Goal: "fix all small change and medium." (the 2026-11-27 repository review, items A 1-17 and B 18-26; 18 is G-6)
Accept:
- System: earlyoom acts before the disk swapfile thrashes (`freeSwapThreshold`, prefer compilers); zram sysctls on workstations; nix-daemon `batch` scheduling; desktop without `common-gpu-amd` (closure diff: no amdgpu in the initrd); laptop thermald/throttled settled by upstream docs.
- Claude Code: the rtk trial ends (hook, guard, its rule text and test removed; rtk dropped, ccusage and ast-grep stay); harmless Playwright MCP tools allowed (`run_code_unsafe`, `evaluate`, `file_upload` not); the settings merge deletes every Nix-owned object key, derived from the managed settings; `skillOverrides` makes the skills personal.md reserves for the user (claude-obsidian save/ingest, brainstorming, graphify) user-invocable only; the Codex config merger is its own file.
- Shell and git: Ctrl-R is fzf in interactive zsh (vi-mode); Nix-owned global git ignores instead of a missing `~/.gitignore_global`; the command-and-control agent identity is in Nix (inline, not a file inside the repository) and `~/.gitconfig` is no longer needed.
- Flake: `nixpkgs-stable`/`pkgs.stable` removed (AGENTS.md updated); `hardware` follows nixpkgs; dead group names gone and an assertion that flodet is in no root-equivalent group (docker, lxd, libvirtd, podman); deploy docs use `--use-substitutes`.
- Checks: CI builds the flake checks instead of copying them (the jail VM test where KVM exists); `systemd.enableStrictShellChecks`; one nix-config checkout script for home and server that leaves a retryable state.
- Gate green after each item.
Not in scope: review items C 27-30, project snapshots, egress control.
Assumptions:
- "fix all" includes removing `nixpkgs-stable` (re-add when a broken package needs it) and ending rtk entirely rather than keeping dead code behind a switch (git keeps it).
- Deleting the old plugin logs (`~/.claude/bash-commands.log`, `cost-tracker.log`, `~/.gateguard`) and the `result` link: refused by the permission system for the agent; listed for the user.

| Item | What | Status | Commit |
|---|---|---|---|
| I1 system-tuning | earlyoom, zram sysctls, daemon batch, desktop amdgpu, laptop thermald | open | |
| I2 claude-code | rtk removal, Playwright allow, merge del list, skillOverrides, codex merger file | open | |
| I3 shell-git | fzf Ctrl-R, git ignores, agent identity in Nix | open | |
| I4 flake-hygiene | stable input, hardware follows, groups + assertion, --use-substitutes docs | open | |
| I5 checkout-dedupe | one nix-config checkout script, retryable | open | |
| I6 ci-checks | CI runs flake checks, strict shell checks for units | open | |

## G-6 jail as its own package  (status: open)

Goal: "Shouldn't jail be its own tool and just called in nixos? Like a package? Can be owned in this repo, but I think that would be cleaner" (plus review items 7, 22, 23)
Accept:
- `pkgs/jail` builds `jail`, `jail-push` and their helpers from `.sh` files (shellcheck as today); exported as `packages.x86_64-linux.jail` and `pkgs.jail` (additions overlay); workstations install it in `environment.systemPackages`; the home-manager module is gone; behavior unchanged (`checks.x86_64-linux.jail` passes, moved next to the package).
- One-off jails get the home-manager session variables (NUGET_PACKAGES, NPM_CONFIG_CACHE, PATH with ~/.local/bin) like the jail's shell.
- A jail's `~/.cache` lives in `~/.cache/jails/<name>` (outside the /home snapshots), bound with the same checks; `.jail` refuses `~/.cache/jails`.
- Codex inside a jail uses a jail profile (network and its caches without approval prompts); the host default stays.
- Commits inside a jail are unsigned (`commit.gpgsign`/`tag.gpgSign` false there; no gpg-agent inside), so `git commit` in a jail works; the host keeps signing.
- Docs (jail.md, agent-isolation.md, ADR 0001 note) updated; Gate green.
Not in scope: a separate flake or repository for jail.
Assumptions:
- Installed system-wide on workstations (it is per-user at runtime: state under ~/.local/share/jails).
- User 2026-11-27: "inside jail i don't commit myself, so keep it unsigned".

| Item | What | Status | Commit |
|---|---|---|---|
| I1 jail-package | pkgs/jail with .sh files, system install, test moved | done | bb52bd6 |
| I2 jail-env-cache | one-off env, cache outside snapshots, codex jail profile, unsigned commits | open | |
