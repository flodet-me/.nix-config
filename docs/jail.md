# Repository jail

`jail` opens a repository in a bubblewrap jail that you and the agents share;
`jail-push` pushes its commits from outside. Package: `pkgs/jail/` (the
scripts are its `.sh` files, `default.nix` builds them; `nix build .#jail`,
`pkgs.jail`), installed system-wide on the workstations
(`hosts/_shared/components/workstation.nix`); state stays per user. It needs
an activated home-manager generation (dotfiles for the jail home). Design
and reasons: [agent-isolation.md](agent-isolation.md),
[ADR 0001](adr/0001-repository-jail.md).

## Use

```sh
jail ~/Projects/foo            # a shell in foo's jail (tmux); every terminal attaches to the same one
claude / codex / nvim          # started from that shell
jail ~/Projects/foo -- make    # a one-off command in a fresh jail, exit status passed on
jail-push ~/Projects/foo       # outside the jail: push the current branch
jail-push ~/Projects/foo main --force-with-lease   # other git push arguments
```

- A one-off command gets home-manager's session variables
  (`hm-session-vars.sh` of your generation: `NUGET_PACKAGES`,
  `NPM_CONFIG_CACHE`, `~/.local/bin` in `PATH`, ...), as the jail's shell does.
- `DIR` defaults to the current directory for `jail`; `jail-push` needs it
  (an existing directory). The jail covers the nearest directory above it
  with a real `.git` directory, or a container's `.git` file (below), so
  worktrees and submodules inside a repository use that repository's jail. A
  repository created inside a jail
  (nested, or a new folder) gets its own jail on its first `jail` start, and
  the URL printed then may come from jailed code: check it.
- A container of worktrees around a bare repository (`<root>/.bare`,
  `<root>/.git` a file `gitdir: ./.bare`, worktrees such as `<root>/main`
  made with `git worktree add`) has one jail for the container and all its
  worktrees: `jail <root>` and `jail <root>/main` are the same jail, with the
  whole container bound at its path, so git works in every worktree.
  `<root>/.git` must be a regular file `gitdir: ./<name>` (or `gitdir:
  <name>`), `<name>` one directory directly in `<root>` that is a bare
  repository (`HEAD`, `objects/`, `refs/`), not a link; anything else there is
  refused or not taken as a container. `.jail` is `<root>/.jail`.
- The first `jail` starts a user unit `jail-<name>` (`<name>`: folder name
  plus a hash of its path) with a tmux server inside. Detach with the tmux
  prefix + `d`; the jail ends when its last tmux window closes, or with
  `systemctl --user stop jail-<name>`.
- A `.jail` file in the repository adds ports and folders to its jail once
  you approve it (below).
- Once a repository has a jail, work on it only inside: a host shell, editor
  or IDE runs code the jail wrote (a git prompt runs `core.fsmonitor`,
  direnv's `use flake` runs the flake's shell hook, VS Code runs tasks and
  extensions). `jail-push` is the one command meant for outside.

## What the jail sees

| | |
| --- | --- |
| read-write | the repository; its cache `~/.cache/jails/<name>`, bound as `~/.cache`; `rw` paths of an approved `.jail`; `~/brain/inbox`; the login: `~/.claude/.credentials.json`, `~/.codex/auth.json` (and its lock files); the Nix daemon socket; `/dev/kvm`; a D-Bus proxy at `/run/user/<uid>/bus` (`org.freedesktop.Notifications` only) |
| read-only | `ro` paths of an approved `.jail`; `/nix`, `/etc`, `/run/current-system`, `/bin`, `/usr`, `/lib64`; its own `resolv.conf` (`~/.local/share/jails/<name>/resolv.conf`, bound over the host's); `~/brain`; every other entry of `~/.claude` and `~/.codex` (`CLAUDE.md`, `settings.json`, `rules/`, `skills/`, `agents/`, `plugins/`, the status line script, `config.toml`, `AGENTS.md`, ...); `~/.local/bin` and `~/.local/share/uv/tools` (graphify) |
| own | `$HOME` is `~/.local/share/jails/<name>/home` (history, nvim state and `:trust` list, direnv allow list, caches, ...) with home-manager's dotfiles linked in on every start; in it the jail's own `~/.claude` and `~/.codex` state (transcripts, memory, plans, shell snapshots, todos, logs, the codex databases; the lists are in `pkgs/jail/default.nix`), `~/.claude/plugins/data` (`~/.local/share/jails/<name>/claude-plugin-data`) and `~/.claude.json`; `/tmp`, `/proc`, `/dev`, an empty `/run/user/<uid>` but for the D-Bus proxy; its own network namespace (below) |
| absent | the rest of `/home`, `/run/user` sockets (the session bus itself, gpg-agent, Docker), services on the host's loopback, the host's abstract Unix sockets, `/run/wrappers` (setuid, and `no_new_privs` stops `sudo` anyway), `/run/secrets` |

On every start `~/.claude.json` gets `oauthAccount`, `userID`,
`mcpServers` and the onboarding flags from yours (one way, the jail's own
project state stays), in a sandbox that sees only the jail home, so a link the
jail planted there reaches no host file.

The caches (`~/.cache/nix`, NuGet and npm, which home-manager points into
`~/.cache`) are per jail too, so the first build in a new jail downloads its
packages again; `/nix/store` is shared through the daemon as usual. A jail's
`~/.cache` is `~/.cache/jails/<name>`, on the `~/.cache` subvolume outside
the `/home` snapshots (bound by fd like the repository, below). Jails from
before kept it in the jail home: on its first start `jail` says so, and
`~/.local/share/jails/<name>/home/.cache` is no longer used; delete it while
that jail is stopped (`jail` never deletes it). Caches outside `~/.cache`
(Cargo's `~/.cargo`) stay in the jail home.

The environment is built, not inherited: `HOME`, `USER`, `LOGNAME`, `PATH`
(per-user profile, system), `SHELL`, `LANG`, `XDG_RUNTIME_DIR` and, if set,
`TERM`, `COLORTERM`, `EDITOR`, `LOCALE_ARCHIVE`, `TERMINFO_DIRS`, `TZDIR`, and
`DBUS_SESSION_BUS_ADDRESS` for the proxy; `JAIL` (the jail's name) and
`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` setting
`commit.gpgSign` and `tag.gpgSign` to false, so commits and tags inside are
unsigned (there is no gpg-agent inside, and you do not commit there; the
host's git config is unchanged and the host still signs). A one-off command
runs after `hm-session-vars.sh` (its `__HM_SESS_VARS_SOURCED` guard unset
again, so a shell it starts, whose `/etc/zshenv` rebuilds `PATH`, sources
it again).

Codex: with `JAIL` set, the `codex` wrapper
(`home/flodet/_shared/components/claude-code/codex/wrapper.nix`) adds
`--profile jail`, which layers `~/.codex/jail.config.toml` (read-only in the
jail like `config.toml`) on your config: `sandbox_mode = "danger-full-access"`
and `approval_policy = "never"`, codex's own "full access". The jail is the
boundary, so codex runs commands without its own sandbox or prompts, with
the network and the jail's caches; `workspace-write` would still ask for
every write outside the repository (`~/.cache`). Codex 0.171 refuses
`--profile` for commands that start no session (`login`, `features`,
`doctor`, ...), so those run without it. Outside a jail codex keeps your
default (`config.toml`); `claude-codex-review` runs plain codex with its
explicit read-only sandbox, also inside.

## Per-repository config (.jail)

A `.jail` at the repository root (the directory `jail` resolves; in a
container of worktrees the container, not a worktree) asks for
more than the defaults:

```sh
# a dev server, reached from your browser
port 5173
# read-only, at the same path inside
ro ~/Datasets/images
# read-write
rw /srv/scratch/foo
```

- `port N` (1024 to 65535): TCP connections to the host's `127.0.0.1:N`
  reach the jail's `127.0.0.1:N` (pasta `--host-lo-to-ns-lo -t
  127.0.0.1/N`). Only host to jail: the jail still reaches no host port. The
  server inside must listen on `127.0.0.1` or `0.0.0.0` (`--host 127.0.0.1`),
  not on `::1` only. A forwarded port is open to every local process and
  user of the host, as any listener on `127.0.0.1` is; and while the jail
  runs it holds the port, so a host service that starts later on the same
  port cannot bind it (and a client of that service talks to the jail).
- `ro PATH`, `rw PATH`: a directory or file bound at the same absolute path
  (`~/` is your home). It must exist, and its path must have no symlink in it
  and be canonical (no `.`, `..`). Refused: `/`, `/tmp`, anything in `/nix`,
  `/run`, `/proc`, `/dev`, `/etc`, `/sys`, `/.snapshots`, `/persist`, your home or a folder above it
  (`/home`), the jails' state (`~/.local/share/jails`, or a folder above it
  such as `~/.local`), the jails' caches (`~/.cache/jails`, in it or above
  it such as `~/.cache`), and the repository or anything in it or above it.
  Also refused, in it, at it or above it: `~/.ssh`, `~/.gnupg`, `~/.claude`,
  `~/.codex`, `~/.claude.json`, `~/.local/share/keyrings`,
  `~/.password-store`; and as `rw` (fine as `ro`): `~/.config`,
  `~/.local/state`, `~/.local/bin`, `~/brain`.
- `#` starts a comment line (only at the start of a line); blank lines are
  fine; any other line is an error naming the line. A port given twice counts
  once.

Jailed code can write `.jail`, so `jail` applies only a copy you approved,
stored outside the jail in `~/.local/share/jails/<name>/jail.approved`, the
way `direnv allow` works:

- `.jail` is read as data like `.git/config`: a regular file, never through
  a link, no wait on a FIFO, at most 64 KiB.
- When it differs from the approved copy and `jail` runs on a terminal
  (stdin and stderr), it
  shows the diff (the whole file the first time), with control characters
  and other bytes as text (`cat -vT`: an escape is `^[`, a tab `^I`), then
  one line with what it amounts to (`jail: in effect: ports ... | ro ... |
  rw ...`), and applies it once you type `yes`. Refused, without a terminal, or when `.jail` is a link, too
  large or has a bad line: one line says that `.jail` is not applied, and the
  jail starts with the copy you approved last (or with none). A jail never
  fails to start because of an unapproved `.jail`.
- No `.jail`: nothing applied. The approved copy stays and applies again,
  without asking, when the same `.jail` comes back (also when jailed code
  writes it back); remove `jail.approved` (Reset) to be asked again.
- The approved copy is checked again on every start: if a path is gone or
  now goes through a symlink, `jail` stops and names the line.
- The repository and every `ro`/`rw` path are bound by fd: right before bwrap
  (`jail-binds`, under pasta) each is opened, checked to be that very path
  (`/proc/self/fd`, no link on the way) and passed as `--bind-fd`/`--ro-bind-fd`,
  so a link a running jail swaps in after the check (below one of its `rw`
  folders, or a nested repository's folder in the outer one) stops the start
  instead of redirecting the bind. bwrap closes those fds before the jailed
  program runs. Mount points with a link on the way are refused by bwrap.
- Read when a jail starts: the shared jail at its first terminal, every
  one-off jail. A running shared jail keeps its config until it restarts
  (`systemctl --user stop jail-<name>`).
- A port in use on the host (any listener on that port): the shared jail does
  not start and names the port; start it again once the port is free. A
  one-off jail next to it (or another jail holding the port) starts without
  that port and says so.

In the browser, open `http://<anything>.localhost:N` (for example
`http://foo.localhost:5173`) rather than `localhost:N`: browsers keep
cookies per host name, not per port, so a name of its own keeps the jail's
cookies apart from your other local services. The page still runs in your
normal browser: its scripts can send requests to every service on your
host's loopback, and it can read nothing the browser would not let any web
page read. Use a separate browser profile for it if those services matter.

`rw` on a path undoes the isolation for that path: another jailed
repository (its code then runs in both jails), personal data. `rw` on
anything your host session runs or reads as config or instructions
(`~/.config`, a shell rc, `~/.local/bin`, `~/brain`, whose `wiki/hot.md`
every Claude session loads) is a way out of the jail; the list above
refuses the known ones, not every one, and compares paths, not folders:
another path to the same folder (desktop's `/data/projects` is `~/Projects`)
passes, so read the paths you approve. `ro` shows the jail whatever is in
there. Opening a path that a jail swapped for a FIFO waits: stop a one-off
start with Ctrl-C; a shared jail then reports it is not running, and
`systemctl --user stop jail-<name>` clears it for the next start.

## Network and D-Bus

- Each jail (the shared one and every one-off) runs in a network namespace of
  its own, connected by `pasta` (passt, as rootless Podman does): outbound
  TCP, UDP and ICMP leave through ordinary sockets of yours on the host. No
  port is forwarded in either direction (`-t/-u/-T/-U none`), except the TCP
  ports a `.jail` names, from the host's `127.0.0.1` into the jail, and the gateway
  address is not mapped to the host (`--no-map-gw`), so the host's loopback
  services (`127.0.0.1`, `::1`) and its abstract Unix sockets (Xwayland's
  `@/tmp/.X11-unix/X0`, some D-Bus) are out of reach. Loopback inside the
  jail is its own and works (winvm's port forwards on `127.0.0.1` stay inside).
- DNS: the jail's `resolv.conf` names `169.254.1.1`, whose TCP and UDP ports
  53 and 853 (DNS over TLS) pasta forwards (`--dns-forward`) to the same ports
  of the host's first nameserver (`127.0.0.53`, resolved); search and options
  lines are the host's at the jail's start. `/run/systemd/resolve` is not bound.
- With a host session bus (`$XDG_RUNTIME_DIR/bus`), `xdg-dbus-proxy --filter
  --talk=org.freedesktop.Notifications` serves the jail's bus; every other
  name (systemd, secrets, portals, ...) is invisible. Its socket lives in
  `$XDG_RUNTIME_DIR/jails/` (`<name>.bus` for the shared jail,
  `<name>.bus-<pid>` per one-off), outside the jail. Without a session bus the
  jail starts without one.
- pasta and the proxy are children of `jail-run`, the jail's main process
  (the `jail-<name>` unit, or the one-off command): a signal to it (TERM,
  Ctrl-C's INT, HUP) reaches pasta, and pasta has `jail-run`'s death as its
  own (`setpriv --pdeathsig KILL`, so also after a SIGKILL); pasta's end ends
  the jail. `nohup`'s HUP stays ignored, so `nohup jail DIR -- CMD &`
  survives a closed terminal; a script's background job starts with INT
  ignored, so stop such a jail with TERM. The proxy ends when `jail-run`'s pipe to it closes and removes
  its socket. Jailed programs start with no signal ignored (`env
  --default-signal`: a background start ignores SIGINT, pasta ignores
  SIGPIPE). The namespace has no name on disk, so nothing stale is
  left after a stop. bwrap starts as root of pasta's user namespace and drops
  every capability (`--cap-drop ALL`), as it does for a normal user.

Every tmux client `jail` starts (the liveness check and the attach) runs in a
sandbox of its own (`/nix`, `/etc`, the socket): a tmux server, jailed or a
fake one in the writable socket directory, can make a client run a command
(`detach-client -E`, `MSG_SHELL`).

## jail-push

- Keeps a bare mirror in `~/.local/share/jails/<name>/mirror.git`, which the
  jail cannot see. It fetches all branches into it and pushes from there, with
  your normal git and SSH (YubiKey) outside the jail.
- Never runs git in the repository: `remote.origin.url` and `HEAD` are read as
  data (`git config --no-includes` on a copy, so a planted `include.path`
  reads nothing), and `git-upload-pack` runs in a sandbox with only `.git` (a
  container's bare repository) bound read-only (no network, no home), so
  planted `core.fsmonitor`, `core.sshCommand`, hooks or symlinks in it reach
  nothing. `.git` must be a real directory or a container's `.git` file as
  above, `config` and `HEAD` in it regular files (read without following
  links, at most 64 KiB, no wait on a FIFO).
- Without a branch it pushes the current one: `HEAD` of the repository, or
  in a container the HEAD of the worktree `DIR` is in (the bare repository's
  from the container itself or a folder outside the worktrees). The
  worktree's `.git` must name exactly `<root>/<name>/worktrees/<n>` (the
  absolute path, or git's relative form with `worktree.useRelativePaths`);
  otherwise, or if `worktrees` is a link, name the branch. URLs with control
  characters are refused, and URLs are printed quoted.
- The push URL is recorded when `jail` first starts for the repository, before
  any jailed code ran for it, and stored in the mirror; later changes in the
  repository are ignored. If none was recorded then (no remote yet, or one
  refused), the first `jail-push` shows `remote.origin.url`, which jailed code
  may have written, and pushes only after you type `yes` on a terminal.
  Allowed: `ssh://`, `https://`, `user@host:path`, or the absolute path of a
  bare repository (pushed through a sandboxed `git-receive-pack`, so its hooks
  run without network or home). To change it:
  `git --git-dir ~/.local/share/jails/<name>/mirror.git remote set-url origin <url>`.

## Reset

```sh
systemctl --user stop jail-<name>
rm -rf ~/.local/share/jails/<name>/home      # jail home (history, nvim state, trust lists, Claude/Codex state)
rm -rf ~/.local/share/jails/<name>/claude-plugin-data   # its Claude plugin data
rm -rf ~/.local/share/jails/<name>/jail.approved      # the approved .jail: the next start asks again
rm -rf ~/.local/share/jails/<name>           # also the push mirror and its stored URL
rm -rf ~/.cache/jails/<name>                 # its caches (~/.cache inside)
rm -rf ~/.local/share/jails/<name>/home/.cache   # the cache of a jail from before ~/.cache/jails, unused
```

After the last line the next `jail` start records the URL again from the
repository, which jailed code may have changed: check the URL it prints; and
it asks again about `.jail`.

## Tested

`nix build .#checks.x86_64-linux.jail` (NixOS VM; the test script itself takes
about 140 s, with a second VM): hidden home paths and `~/.cache/docker` absent; `~/brain` read-only
except `inbox/`; writes to `~/.claude` config (`CLAUDE.md`, `settings.json`,
`skills/`, `rules/`, `agents/`, `plugins/`) and `~/.codex` (`config.toml`,
`AGENTS.md`, `rules/`) fail; the logins are shared; state written in
`~/.claude` (new names, `projects/`, `shell-snapshots/`, `plugins/data/`),
`~/.codex/sessions` and `~/.cache/nix` does not reach the host, and the
host's is not visible; `~/.claude.json` gets the login and MCP servers and
keeps the jail's projects, the host file stays unchanged, also with a link
planted in its place; home-manager files linked;
`/usr/bin/env` works; a one-off command sees a home-manager session
variable and `home.sessionPath`; the jail's `~/.cache` is in
`~/.cache/jails/<name>` (not in the jail home), also with a link planted at
its mount point, and an old cache in the jail home stays, unused, with one
message; codex inside reports `danger-full-access` (`codex debug
prompt-input`, the host's default outside) and `codex features list` works
there; with `commit.gpgSign` and `tag.gpgSign` true in a repository a commit
and an annotated tag fail outside (no key) and work unsigned inside; no capabilities (also none in the bounding set); no
ignored signals (a one-off jail and the shared jail's processes);
`sudo`, `systemd-run --user` and gpg-agent unavailable, the only socket in `/run/user` the D-Bus proxy, which
answers for `org.freedesktop.Notifications` (a stand-in on the session bus) and
not for another name; outbound TCP to a second test node and DNS (UDP and TCP,
via resolved on the test VM) work, host listeners on `127.0.0.1` and `::1`, the same port
on the namespace's gateway and a host abstract socket are unreachable,
loopback inside works; neither pasta, the jailed command nor the proxy and its
socket outlive a one-off jail, also one ended by TERM, INT or KILL, or a
stopped shared jail; `nix build` through the daemon; `/dev/kvm` inside iff
outside; a link planted at a mount point does not stop the next start;
`jail-push` pushes over ssh without running planted hooks, `core.fsmonitor`,
`core.sshCommand` (the global one runs) or `uploadpack.packObjectsHook`,
uses the URL `jail` recorded at its first start, asks on a terminal for an
unrecorded one and refuses without a terminal, keeps its stored URL, refuses
`ext::` (allowed in the test's git config), `fd::`, `file://`, option-like and
non-repository URLs and URLs with control characters, a missing `DIR`, a
symlinked `.git`, a `.git/config` or `HEAD` that is a link to another
repository's or a FIFO, and an `include.path` to another repository's config, and runs a local remote's hooks
sandboxed; a container of worktrees (made with `git clone --bare`, a
`gitdir: ./.bare` file and `git worktree add`) has one jail, state and unit
from the container and from a worktree, git commits inside in each worktree,
the URL is recorded from the bare repository at the first start, `jail-push`
from a worktree pushes only its branch (also from a relative-path worktree and
a subfolder), from the container or a folder outside the worktrees the bare
HEAD's, and from a worktree whose `.git` points elsewhere (another repository,
the bare repository itself, a `..` path out of it), whose git directory is a
FIFO (no wait) or whose `worktrees` is a link nothing without a named branch;
a container `.git` naming another repository, an absolute or `..` path, `./`,
a link, an empty directory or a FIFO instead of the bare repository, or a
FIFO as `.git` (no wait on either) is refused by `jail` and `jail-push`, from the container and
from a worktree; a linked worktree and a submodule of a normal repository use
its jail, and `jail-push` from the worktree pushes the repository's HEAD;
two terminals share
one tmux server and one unit, the shell in it is jailed, and a
`detach-client -E` command does not run on the host, the shared jail reaches
the Notifications stand-in and the second node and starts again after a stop;
a `.jail` with a port, a `ro` and an `rw` folder is not applied before
approval (without a terminal, or answered `no`), shows its content and then a
diff with an escape sequence as `^[`, and once approved with `yes` (a typed
answer through `script`) the `ro` folder is readable and not writable, the
`rw` one writable, the host reaches listeners on the jail's `127.0.0.1:8090`
and `:8091` (one-off; `8090` also in the shared jail), forwarded from the
host's `127.0.0.1` only, a port given twice counted once, while the jail still does not reach the host's
loopback; a one-off next to a jail holding the port starts without it, a
shared jail with the port taken on the host does not start and names the
port, then starts once it is free; a jail-side edit adding `rw` of a host file
is not applied without approval and the approved copy stays in use; a linked
`.jail`, a linked path, forbidden paths (`/`, `/home`, `~`, `~/.local`, the
jails' state, `~/.cache`, `~/.cache/jails` and a folder in it, `/etc`, `/nix/store`, `/run/user`, `/proc`, `/tmp`, the
repository and its `.git`, `~/.ssh`, `~/.gnupg`, `~/.claude` and below it,
`~/.codex`, `~/.claude.json`, keyrings, `~/.password-store`, and as `rw`
`~/.config`, `~/.local/state`, `~/.local/bin`, `~/brain`), relative and
missing paths, ports below 1024 or above 65535 and unknown keywords are
refused with the line named, and nothing is applied; the approval shows a tab
as `^I` and the line with what is in effect; a `.jail` over 64 KiB, a FIFO
(no wait) or a directory is not applied; an approved path that is gone stops
the start; `jail-binds` refuses a bind source that is a link when it opens
it (a swap after the check) and the jail holds no fd beyond 0 to 2
(a fake server answering
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
  `pkgs/jail/default.nix` comes in read-only, and the program fails to write it: add its
  name to the list.
- The shared login is one file bound into the jail. Claude Code outside
  saves it by rename, so after a token refresh outside, a running jail keeps
  the old file (and writes a refresh of its own there) until it restarts; if
  its old token is refused, log in inside or restart the jail. Its OAuth
  refresh lock is per jail as well. How codex saves `auth.json` is not
  checked.
- `mcpServers` come from your `~/.claude.json`, environment (and any token in
  it) included.
- The same holds for any host file bound into the jail and replaced by
  rename on the host (an editor save, home-manager): a running jail keeps the
  old one until it restarts.
- Home-manager files at paths the jail replaced with its own stay the jail's
  (reset the jail home to get them back).
- No `/sys`, `/run/opengl-driver`, Wayland or X11 sockets in the file system:
  GUI programs and GPU compute do not run inside.
- Outbound traffic leaves as yours from the host, so the host's services on
  addresses of other interfaces and the LAN are reachable as from any program
  of yours; only loopback and abstract sockets are cut. A host listener on
  `0.0.0.0` or `[::]` answers on every host address, for example Docker's
  `docker0` (`172.17.0.1`), libvirt's `virbr0` (`192.168.122.1`), Tailscale or
  the LAN address; only one bound to `127.0.0.1` or `::1` is out of reach. The one deliberate path to host loopback is pasta's DNS
  forwarder to your nameserver on ports 53 and 853. There is no egress allowlist.
- The namespace copies the host's addresses and routes when the jail starts
  (offline: a link-local fallback) and keeps them: after a network change
  (another Wi-Fi, a VPN), restart the jail if outbound or DNS misbehave.
- A notification is the one D-Bus call that leaves: its text and actions are
  the jail's, so it can show a misleading message. `--talk` opens the whole
  connection that owns `org.freedesktop.Notifications`, every object and
  method of it, not only the notification interface. On GNOME that is a
  separate process of gnome-shell (`org.gnome.Shell.Notifications`), which
  serves only notifications; with another desktop, check what owns the name.
- A tmux server inside the jail (or a fake one in the socket directory) can
  draw anything in your terminal, also a prompt that looks like the host's;
  it cannot type into other programs (TIOCSTI is off or blocked).
- Home-manager's files are linked when a jail starts; after a switch, restart
  the jail to pick them up.
- A tmux server with the jail stays alive while a window is open, also with no
  terminal attached.
