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
| read-write | the repository; `~/brain/inbox`; `~/.cache/{nix,nuget,npm}`, `~/.cargo/registry` (shared caches, never `~/.cache` as a whole: rootless Docker's data is in `~/.cache/docker`); `~/.claude`, `~/.claude.json`, `~/.codex` (one shared login); the Nix daemon socket; `/dev/kvm` |
| read-only | `/nix`, `/etc`, `/run/current-system`, `/bin`, `/usr`, `/lib64`, DNS (`/run/systemd/resolve`); `~/brain`; `~/.claude/{settings.json,rules,skills,agents}`; `~/.local/bin` and `~/.local/share/uv/tools` (graphify) |
| own | `$HOME` is `~/.local/share/jails/<name>/home` (history, nvim state and `:trust` list, direnv allow list, ...) with home-manager's dotfiles linked in on every start; `/tmp`, `/proc`, `/dev`, an empty `/run/user/<uid>` |
| absent | the rest of `/home`, `/run/user` sockets (session bus, gpg-agent, Docker), `/run/wrappers` (setuid, and `no_new_privs` stops `sudo` anyway), `/run/secrets` |

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
about 25 s): hidden home paths and `~/.cache/docker` absent; `~/brain` read-only
except `inbox/`; the Claude read-only paths; home-manager files linked;
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

- Shared and writable by every jail, and code that other sessions run:
  `~/.claude/plugins` (plugin hooks), `mcpServers` in `~/.claude.json`,
  `~/.claude/ponytail-statusline.sh` (run by the status line), `~/.codex/config.toml`
  (`notify`). A jail can plant code there that runs in other jails, or outside
  when you start `claude`/`codex` outside a jail.
- The shared caches are consumed by builds outside a jail too: a jail can
  plant entries in `~/.cache/nix` (eval and fetcher caches), `~/.cache/nuget`
  and `~/.cargo/registry` (extracted packages).
- Single files bound into the jail (`~/.claude.json`, `~/.claude/settings.json`)
  cannot be replaced by rename inside it, and a rename on the host leaves the
  jail with the old file until it restarts.
- No `/sys`, `/run/opengl-driver`, Wayland or X11: GUI programs and GPU compute
  do not run inside.
- Home-manager's files are linked when a jail starts; after a switch, restart
  the jail to pick them up.
- A tmux server with the jail stays alive while a window is open, also with no
  terminal attached.
