# Repository jail

`jail` opens a repository in a bubblewrap jail that you and the agents share;
`jail-push` pushes its commits from outside. Module:
`home/flodet/_shared/components/jail/` (workstations). Design and reasons:
[agent-isolation.md](agent-isolation.md), [ADR 0001](adr/0001-repository-jail.md).

## Use

```sh
jail ~/Projects/foo            # a shell in foo's jail (tmux); every terminal attaches to the same one
claude / codex / nvim          # started from that shell
jail ~/Projects/foo -- make    # a one-off command in a fresh jail, exit status passed on
jail-push ~/Projects/foo       # outside the jail: push the current branch
jail-push ~/Projects/foo main --force-with-lease   # other git push arguments
```

- `DIR` defaults to the current directory; the jail covers the nearest
  directory above it with a real `.git` directory, so worktrees and submodules
  inside a repository use that repository's jail.
- The first `jail` starts a user unit `jail-<name>` (`<name>`: folder name
  plus a hash of its path) with a tmux server inside. Detach with the tmux
  prefix + `d`; the jail ends when its last tmux window closes, or with
  `systemctl --user stop jail-<name>`.

## What the jail sees

| | |
| --- | --- |
| read-write | the repository; `~/brain/inbox`; the login: `~/.claude/.credentials.json`, `~/.codex/auth.json` (and its lock files); the Nix daemon socket; `/dev/kvm` |
| read-only | `/nix`, `/etc`, `/run/current-system`, `/bin`, `/usr`, `/lib64`, DNS (`/run/systemd/resolve`); `~/brain`; every other entry of `~/.claude` and `~/.codex` (`CLAUDE.md`, `settings.json`, `rules/`, `skills/`, `agents/`, `plugins/`, the status line script, `config.toml`, `AGENTS.md`, ...); `~/.local/bin` and `~/.local/share/uv/tools` (graphify) |
| own | `$HOME` is `~/.local/share/jails/<name>/home` (history, nvim state and `:trust` list, direnv allow list, caches, ...) with home-manager's dotfiles linked in on every start; in it the jail's own `~/.claude` and `~/.codex` state (transcripts, memory, plans, shell snapshots, todos, logs, the codex databases; the lists are in `default.nix`), `~/.claude/plugins/data` (`~/.local/share/jails/<name>/claude-plugin-data`) and `~/.claude.json`; `/tmp`, `/proc`, `/dev`, an empty `/run/user/<uid>` |
| absent | the rest of `/home`, `/run/user` sockets (session bus, gpg-agent, Docker), `/run/wrappers` (setuid, and `no_new_privs` stops `sudo` anyway), `/run/secrets` |

On every start `~/.claude.json` gets `oauthAccount`, `userID`,
`mcpServers` and the onboarding flags from yours (one way, the jail's own
project state stays), in a sandbox that sees only the jail home, so a link the
jail planted there reaches no host file.

The caches (`~/.cache/nix`, NuGet, npm, Cargo) are per jail too, so the
first build in a new jail downloads its packages again; `/nix/store` is
shared through the daemon as usual.

The environment is built, not inherited: `HOME`, `USER`, `LOGNAME`, `PATH`
(per-user profile, system), `SHELL`, `LANG`, `XDG_RUNTIME_DIR` and, if set,
`TERM`, `COLORTERM`, `EDITOR`, `LOCALE_ARCHIVE`, `TERMINFO_DIRS`, `TZDIR`. Network
is shared with the host for now (design step 3 gives it its own namespace).

Every tmux client `jail` starts (the liveness check and the attach) runs in a
sandbox of its own (`/nix`, `/etc`, the socket): a tmux server, jailed or a
fake one in the writable socket directory, can make a client run a command
(`detach-client -E`, `MSG_SHELL`).

## jail-push

- Keeps a bare mirror in `~/.local/share/jails/<name>/mirror.git`, which the
  jail cannot see. It fetches all branches into it and pushes from there, with
  your normal git and SSH (YubiKey) outside the jail.
- Never runs git in the repository: `remote.origin.url` and `HEAD` are read as
  data, and `git-upload-pack` runs in a sandbox with only `.git` bound
  read-only (no network, no home), so planted `core.fsmonitor`,
  `core.sshCommand`, hooks or symlinks in `.git` reach nothing. `.git` must be
  a real directory.
- The push URL is taken from `remote.origin.url` on the first push, printed and
  stored in the mirror; later changes in the repository are ignored. Allowed:
  `ssh://`, `https://`, `user@host:path`, or the absolute path of a bare
  repository (pushed through a sandboxed `git-receive-pack`, so its hooks run
  without network or home). To change it:
  `git --git-dir ~/.local/share/jails/<name>/mirror.git remote set-url origin <url>`.

## Reset

```sh
systemctl --user stop jail-<name>
rm -rf ~/.local/share/jails/<name>/home      # jail home (history, nvim state, trust lists)
rm -rf ~/.local/share/jails/<name>           # also the push mirror and its stored URL
```

## Tested

`nix build .#checks.x86_64-linux.jail` (NixOS VM; the test script itself takes
about 28 s): hidden home paths and `~/.cache/docker` absent; `~/brain` read-only
except `inbox/`; writes to `~/.claude` config (`CLAUDE.md`, `settings.json`,
`skills/`, `rules/`, `agents/`, `plugins/`) and `~/.codex` (`config.toml`,
`AGENTS.md`, `rules/`) fail; the logins are shared; state written in
`~/.claude` (new names, `projects/`, `shell-snapshots/`, `plugins/data/`),
`~/.codex/sessions` and `~/.cache/nix` does not reach the host, and the
host's is not visible; `~/.claude.json` gets the login and MCP servers and
keeps the jail's projects, the host file stays unchanged, also with a link
planted in its place; home-manager files linked;
`/usr/bin/env` works; `sudo`, `systemd-run --user`, the session bus and
gpg-agent unavailable; `nix build` through the daemon; `/dev/kvm` inside iff
outside; `jail-push` pushes without running planted hooks, `core.fsmonitor`,
`core.sshCommand` or `uploadpack.packObjectsHook`, keeps its stored URL,
refuses `ext::`, `fd::`, `file://`, option-like and non-repository URLs and a
symlinked `.git`, and runs a local remote's hooks sandboxed; two terminals share
one tmux server and one unit, the shell in it is jailed, and a
`detach-client -E` command does not run on the host (a fake server answering
the liveness check is covered by construction, the same sandbox, not by a
test). Every negative check has
a positive control outside the jail.

## Limits

- Writes the jail makes to its read-only entries fail: codex saving a
  setting or a trusted folder (`config.toml`), Claude Code's settings toggles
  (`settings.json`), plugin installs and marketplace updates (`plugins/`; the
  `claude-plugins-sync` service installs them outside). Change those outside
  the jail.
- A host entry of `~/.claude`/`~/.codex` that is state but not in the lists in
  `default.nix` comes in read-only, and the program fails to write it: add its
  name to the list.
- Claude Code's OAuth refresh lock is a directory next to the shared
  credentials, so it is per jail: a token refresh inside and outside a jail
  at the same moment can still race and ask for a new login.
- `mcpServers` come from your `~/.claude.json`, environment (and any token in
  it) included.
- A host file bound into the jail and replaced by rename on the host (an
  editor save, home-manager) stays the old file in a running jail until it
  restarts.
- No `/sys`, `/run/opengl-driver`, Wayland or X11: GUI programs and GPU compute
  do not run inside.
- Home-manager's files are linked when a jail starts; after a switch, restart
  the jail to pick them up.
- A tmux server with the jail stays alive while a window is open, also with no
  terminal attached.
