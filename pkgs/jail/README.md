# jail

`jail` opens a git repository in a bubblewrap jail. Your shell, Neovim and
the agents (Claude Code, Codex) work inside it, and code run there cannot
read the rest of your home, your keys or the host's services. `jail push`
pushes the jail's commits from outside. Inside every jail this file is
`/run/current-system/sw/share/doc/jail/README.md`. Design, the checks in
detail, the tests and all limits: `docs/jail.md` in the nix-config
repository.

## What the jail sees

- **read-write:** the repository; its own `~/.cache`; the Claude Code and
  Codex logins; `~/brain/inbox`; the Nix daemon; `/dev/kvm`; the `rw` paths
  of an approved `.jail`.
- **read-only:** `/nix`, `/etc`, the system; `~/brain`; your `~/.claude`
  and `~/.codex` config; the `ro` paths of an approved `.jail`.
- **its own:** a home (`~/.local/share/jails/<name>/home`) with your
  home-manager dotfiles linked in, its own Claude Code and Codex state,
  `/tmp`, a network namespace.
- **hidden:** the rest of `/home` (other repositories, documents, SSH and
  GPG keys), gpg-agent and SSH agent, the session bus except notifications,
  services on the host's `127.0.0.1`, `/run/secrets`, `sudo`.

Outbound network works. No host port reaches the jail unless `.jail`
forwards it.

## Start

```sh
jail ~/Projects/foo            # a shell in foo's jail (tmux); every terminal attaches to the same one
jail                           # the same, for the repository around the current directory
jail ~/Projects/foo -- make    # a one-off command in a fresh jail, its exit status passed on
jail config [DIR]              # check DIR's .jail (below); never applies anything
jail help                      # every command, by task (also jail --help)
```

- A jail covers the nearest directory above `DIR` with a `.git` directory,
  so worktrees and submodules use their repository's jail. A container of
  worktrees around a bare repository (`.git` a file `gitdir: ./.bare`) has
  one jail for all of them.
- The first `jail` starts a user unit `jail-<name>` (`<name>`: the folder
  name plus a hash of its path; inside, `$JAIL`) with a tmux server. Detach
  with the tmux prefix + `d`. The jail ends when its last window closes, or
  with `jail stop` (below).
- `config`, `list`, `status`, `stop`, `reset`, `push` and `help` are always
  commands, so that they mean the same in every folder: open a directory
  named `list` as `jail ./list`.
- bash and zsh complete the commands, folders and jail names, and for `jail
  push` the repositories with a jail, then the branches of its mirror.

## Inside

- Start `claude`, `codex` and `nvim` from the jail's shell. `$JAIL` is set;
  codex runs with its jail profile (no sandbox or prompts of its own: the
  jail is the boundary).
- direnv loads the repository's `.envrc` (`use flake`) without `direnv
  allow`: the jail writes a whitelist for the repository into its own
  `~/.config/direnv/direnv.toml` on every start. On the host `direnv allow`
  still applies (and you should not allow a jailed repository there).
- Commits are unsigned inside (there is no gpg-agent). Push with
  `jail push` from outside.
- Once a repository has a jail, work on it only inside: a host shell
  prompt, editor or direnv runs code the jail wrote (`core.fsmonitor`, a
  flake's shell hook). `jail push` is the one command meant for outside.
- A port or a folder outside the repository: ask for it in `.jail` (below).

## jail push

```sh
jail push ~/Projects/foo                            # push the current branch
jail push                                           # the same, for the repository around the current directory
jail push ~/Projects/foo main --force-with-lease    # other git push arguments
```

On the host; inside a jail it refuses. The first argument is `DIR` when it
is a directory (one that looks like a path, `/...`, `./...`, `../...`, must
exist); otherwise `DIR` is the current directory and every argument goes to
`git push`. A branch named like a folder here: `jail push . docs`.
`jail-push DIR [ARGS...]` is the same command (`DIR` required).

`jail push` pushes from a mirror the jail cannot see
(`~/.local/share/jails/<name>/mirror.git`) with your git and SSH key, and
never runs git in the repository. The URL is `origin` as recorded at the
first `jail` start; without one, the first `jail push` shows the
repository's URL (jailed code may have written it) and asks for `yes`.

## Ports and folders: .jail

A `.jail` file at the repository root (in a container of worktrees: the
container) asks for more:

```sh
# a dev server, opened in your browser as http://foo.localhost:5173
port 5173
# read-only, at the same path inside
ro ~/Datasets/images
# read-write
rw /srv/scratch/foo
```

- `port N` (1024 to 65535): the host's `127.0.0.1:N` reaches the jail's
  `127.0.0.1:N`, only in that direction. The server inside listens on
  `127.0.0.1` or `0.0.0.0`, not on `::1` only. Use a name of its own
  (`foo.localhost`) in the browser so its cookies stay apart.
- `ro PATH`, `rw PATH`: an existing directory or file, at the same path
  inside. Absolute or `~/...`, no symlink on the way, no `.` or `..`.
- `#` starts a comment line, blank lines are fine; any other line is an
  error naming the line.
- Refused: `/tmp`; anything in `/nix`, `/etc`, `/run`, `/proc`, `/dev`,
  `/sys`, `/.snapshots`, `/persist`; your home and the folders above it
  (`/home`, `/`); the jails' state (`~/.local/share/jails`), `~/.cache` and
  the repository, each with what is in it and above it; in, at or above
  `~/.ssh`, `~/.gnupg`, `~/.claude`, `~/.codex`, `~/.claude.json`,
  `~/.local/share/keyrings`, `~/.password-store`; and as `rw` (fine as `ro`)
  the same for `~/.config`, `~/.local/state`, `~/.local/bin`, `~/brain`.
- `rw` gives up the isolation for that path, and `ro` shows the jail
  whatever is in it: read the paths you approve.

### Check it: jail config

`jail config [DIR]`, inside a jail or on the host, reads the repository's
`.jail` as a start does and prints:

- the path of the `.jail` it read (in a container of worktrees the
  container's);

- an error naming the line (exit status 1);
- `would add: ports ... | ro ... | rw ...`;
- what is in effect: inside, in this jail; on the host, the copy you
  approved;
- whether `.jail` differs from that, and how to get it applied.

It never approves or writes anything. Inside a jail it cannot see the host's
paths, so it skips the checks that `ro`/`rw` paths exist, are a directory or
file, and have no symlink in them; the host makes them when you approve.
Inside, "in effect" comes from the environment the jail started with
(`JAIL_IN_EFFECT`, `JAIL_APPLIED_SHA256`), which code in the jail can
change for itself.

### How a change takes effect

Jailed code can write `.jail`, so `jail` applies only a copy you approved on
a host terminal, as `direnv allow` does:

1. Edit `.jail`, inside or outside.
2. Start the jail again from a host terminal: `jail stop DIR` (this ends
   every shell in it), then `jail DIR`. A one-off
   `jail DIR -- CMD` on a terminal asks the same.
3. `jail` shows the diff (the whole file the first time) and what it amounts
   to, and applies it once you type `yes`.

Without a terminal, after another answer, or with a bad line, the jail
starts with the copy you approved last (or none) and says that `.jail` is
not applied. Without `.jail` nothing is applied; the approved copy applies
again, without asking, when the same `.jail` comes back. A port in use on
the host keeps a shared jail from starting (it names the port); a one-off
jail starts without that port.

## Manage jails

```sh
jail list                     # every jail, one line each
jail status [DIR]             # one jail in detail
jail stop [DIR|NAME]          # stop its shared jail (ends every shell in it)
jail stop --all               # stop every shared jail
jail reset [DIR|NAME] --home  # delete state (below); always asks
```

- `jail list` shows each jail's name, its repository (`?` for a jail last
  started before jail recorded it, `(gone)` when that folder no longer
  exists), whether its shared jail runs and how many one-off jails, its
  `.jail` (`approved`, `pending` your approval, `refused`, or `none`), the
  push URL and the size of its home and cache.
- `jail status [DIR]` prints what `jail config` does, then whether it runs,
  its unit, the tmux clients attached, its state and cache folders and the
  push URL.
- `NAME` is a name from `jail list`; an argument is taken as `NAME` when
  `~/.local/share/jails/NAME` exists and no directory of that name is in the
  current one, otherwise as `DIR`. A jail whose repository is gone is
  reached by its `NAME`.
- `jail stop` stops shared jails only; it says how many one-off jails still
  run (end those where they run).
- These commands run on the host only.

## Reset

```sh
jail reset [DIR|NAME] --approved   # the approved .jail: the next start asks again
jail reset [DIR|NAME] --home       # the jail home (history, nvim state, trust lists, Claude/Codex state) and its Claude plugin data
jail reset [DIR|NAME] --all        # all its state (also the push mirror and its stored URL) and its caches (~/.cache inside)
```

`jail reset` refuses while the jail runs (shared or one-off), lists exactly
what it deletes and asks `y/N` on the terminal; without a terminal it
deletes nothing. After `--all` the next `jail` start records the push URL
again from the repository, which jailed code may have changed: check the URL
it prints. It also asks about `.jail` again. The cache of a jail from before
`~/.cache/jails`, unused, is `~/.local/share/jails/<name>/home/.cache`
(`--home` deletes it).

## Limits

- No GUI programs or GPU compute inside (no Wayland, X11 or `/sys`).
- Writes to your `~/.claude` and `~/.codex` config fail inside (settings
  toggles, plugin installs, codex's trusted folders): change them outside.
- A running jail keeps its `.jail` config, its home-manager files and its
  copy of host files that the host replaces (a login refreshed outside, a
  switch) until it restarts.
- Outbound traffic leaves as yours: the LAN and host services listening on
  other addresses than loopback are reachable. There is no egress
  allowlist.
- A forwarded port is open to every local user and process; a page served
  from the jail runs in your normal browser.
- A tmux server inside can draw anything in your terminal, also a prompt
  that looks like the host's.
- The rest: `docs/jail.md`, Limits.
