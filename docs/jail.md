# Repository jail

`jail` opens a repository in a bubblewrap jail that you and the agents share;
`jail push` (also `jail-push`) pushes its commits from outside. Package: `pkgs/jail/` (the
scripts are its `.sh` files, `default.nix` builds them; `nix build .#jail`,
`pkgs.jail`), installed system-wide on the workstations
(`hosts/_shared/components/workstation.nix`); state stays per user. It needs
an activated home-manager generation (dotfiles for the jail home). Design
and reasons: [agent-isolation.md](agent-isolation.md),
[ADR 0001](adr/0001-repository-jail.md).

How to use it (start, attach, one-off commands, `jail push`, the `.jail`
format, `jail config`, approval and restart, `jail list`/`status`/`stop`,
`jail reset`, the main limits) is the
user guide [pkgs/jail/README.md](../pkgs/jail/README.md), installed as
`share/doc/jail/README.md` (inside every jail:
`/run/current-system/sw/share/doc/jail/README.md`, named by `jail --help`).
This page holds the design details, the checks, the network, the tests and
all limits.

## Starting, in detail

- A one-off command gets home-manager's session variables
  (`hm-session-vars.sh` of your generation: `NUGET_PACKAGES`,
  `NPM_CONFIG_CACHE`, `~/.local/bin` in `PATH`, ...), as the jail's shell does.
- `DIR` defaults to the current directory for `jail` and `jail push`
  (there the first argument is `DIR` only if it is a directory; one that
  looks like a path must exist); `jail-push` needs it (an existing
  directory). `config`, `list`, `status`, `stop`, `reset`, `push` and `help`
  are fixed words, not directories (a directory named `list` is `jail
  ./list`), so a command means the same in every folder, also where a
  repository has a `config/` folder. `list`, `status`, `stop`, `reset` and
  `push` (and `jail-push`) refuse inside a jail (`$JAIL` set): they work on
  the host's state, which the jail does not see. A
  repository created inside a jail (nested, or a new folder) gets its own
  jail on its first `jail` start, and the URL printed then may come from
  jailed code: check it.
- A container of worktrees: `<root>/.git` must be a regular file `gitdir:
  ./<name>` (or `gitdir: <name>`), `<name>` one directory directly in
  `<root>` that is a bare repository (`HEAD`, `objects/`, `refs/`), not a
  link; anything else there is refused or not taken as a container. The
  whole container is bound at its path, so git works in every worktree, and
  `.jail` is `<root>/.jail`.

## What the jail sees

| | |
| --- | --- |
| read-write | the repository; its cache `~/.cache/jails/<name>`, bound as `~/.cache`; `rw` paths of an approved `.jail`; `~/brain/inbox`; the login: `~/.claude/.credentials.json`, `~/.codex/auth.json` (and its lock files); the Nix daemon socket; `/dev/kvm`; a D-Bus proxy at `/run/user/<uid>/bus` (`org.freedesktop.Notifications` only) |
| read-only | `ro` paths of an approved `.jail`; `/nix`, `/etc`, `/run/current-system`, `/bin`, `/usr`, `/lib64`; its own `resolv.conf` (`~/.local/share/jails/<name>/resolv.conf`, bound over the host's); `~/brain`; every other entry of `~/.claude` and `~/.codex` (`CLAUDE.md`, `settings.json`, `rules/`, `skills/`, `agents/`, `plugins/`, the status line script, `config.toml`, `AGENTS.md`, ...); `~/.local/bin` and `~/.local/share/uv/tools` (graphify) |
| own | `$HOME` is `~/.local/share/jails/<name>/home` (history, nvim state and `:trust` list, direnv allow list, caches outside `~/.cache`, ...) with home-manager's dotfiles linked in on every start, and a direnv whitelist for the repository (`~/.config/direnv/direnv.toml`, rewritten on every start: `.envrc` runs as jailed code there, so it needs no `direnv allow`); in it the jail's own `~/.claude` and `~/.codex` state (transcripts, memory, plans, shell snapshots, todos, logs, the codex databases; the lists are in `pkgs/jail/default.nix`), `~/.claude/plugins/data` (`~/.local/share/jails/<name>/claude-plugin-data`) and `~/.claude.json`; `/tmp`, `/proc`, `/dev`, an empty `/run/user/<uid>` but for the D-Bus proxy; its own network namespace (below) and UTS namespace, named like the host (pasta's `pasta-<host>` is in no `/etc/hosts`, and without nscd nothing else resolves it) |
| absent | the rest of `/home`, `/run/user` sockets (the session bus itself, gpg-agent, Docker), services on the host's loopback, the host's abstract Unix sockets, `/run/wrappers` (setuid, and `no_new_privs` stops `sudo` anyway; with `containers` it holds podman and docker, below), `/run/secrets` |

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
that jail is stopped (`jail` never deletes it; it says so only when there is
more in it than home-manager's links). Caches outside `~/.cache`
(Cargo's `~/.cargo`) stay in the jail home.

The environment is built, not inherited: `HOME`, `USER`, `LOGNAME`, `PATH`
(per-user profile, system), `SHELL`, `LANG`, `XDG_RUNTIME_DIR` and, if set,
`TERM`, `COLORTERM`, `EDITOR`, `LOCALE_ARCHIVE`, `TERMINFO_DIRS`, `TZDIR`, and
`DBUS_SESSION_BUS_ADDRESS` for the proxy; `JAIL` (the jail's name),
`JAIL_IN_EFFECT` and `JAIL_APPLIED_SHA256` (for `jail config`, below), and
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
`doctor`, ...), so those run without it; the wrapper finds the command
after codex's global options (`codex -c k=v login`), and adds nothing when
you give `-p`/`--profile` yourself. Without `~/.codex/jail.config.toml`
(before the switch that brings it) codex silently keeps the host default
(`read-only` or `workspace-write`), which is more restrictive: it asks
again. Outside a jail codex keeps your
default (`config.toml`); `claude-codex-review` runs plain codex with its
explicit read-only sandbox, also inside.

Both agents carry a few lines for jails (`~/.claude/rules/jail.md`, the end
of `~/.codex/AGENTS.md`, from `home/flodet/_shared/components/claude-code/`):
when a port or a path outside the repository is unreachable and `$JAIL` is
set, edit `.jail`, check it with `jail config`, and tell you that it applies
only after your approval at the next start. They are loaded in every session,
in and outside jails (the files are host config, read-only in the jail), so
they are worded for `$JAIL`.

## Per-repository config (.jail)

The format, with examples, and how a change is approved: the user guide
(`.jail` and `jail config`). The details:

- `port N`: pasta `--host-lo-to-ns-lo -t 127.0.0.1/N`; the jail still
  reaches no host port. A server started with `--host 127.0.0.1` is reached.
  While the jail runs it holds the port, so a host service that starts later
  on the same port cannot bind it (and a client of that service talks to the
  jail).
- `ro`, `rw` (`bind_path`): `~` and `~/` are your home, trailing slashes go;
  the path must equal its `realpath -e` (so it exists, has no symlink on the
  way and is canonical) and be a directory or regular file. The refused
  paths (the list is in the guide) are compared as paths: "in" is at or
  below, "above" a folder that contains it: your home only at or above, the
  repository, `~/.cache` and the jails' state also below, the keys and logins
  and the `rw`-only list in either direction, `/tmp` only itself.
- A comment is a line starting with `#` (after blanks); `#` later in a line
  is not one. A port given twice counts once.
- `jail config [DIR]` reads `.jail` with the same function as a start
  (`read_jail`: regular file, no link, no FIFO wait, 64 KiB) and the same
  `parse`/`bind_path`, and exits before anything that writes (the first
  start's push URL, the jail home, the cache). On the host it compares with
  `jail.approved`. Inside, a start passes what it applied as `JAIL_IN_EFFECT`
  (ports forwarded, `ro`, `rw`) and `JAIL_APPLIED_SHA256` (of the applied
  text, compared with `.jail` as read); the approved copy stays invisible.
  Jailed code can change those variables for its own processes: they inform,
  the approval on the host decides. Inside, `bind_path` skips the checks that
  need the host's paths (exists, directory or regular file, no symlink; it
  still refuses a path that is not canonical, `realpath -sm`) and `jail
  config` says so; that skip is set only in the
  `jail config` branch, never from the environment, so a start always checks.
  A `DIR` whose repository is not this jail's (a nested repository) gets no
  "in effect".

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
  rw ...`), and applies it once you type `yes`. Refused, without a
  terminal, or when `.jail` is a link, too large or has a bad line: one line
  says that `.jail` is not applied, and the jail starts with the copy you approved last (or with none). A jail never
  fails to start because of an unapproved `.jail`.
- The approved copy also stays without `.jail` and comes back when jailed
  code writes the same `.jail` back; remove `jail.approved` (Reset) to be
  asked again.
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
  one-off jail. Ports are checked with `ss` before the start; a port held by
  another jail counts as in use.

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
every Claude session loads) is a way out of the jail; the list of refused
paths in the user guide (`bind_path`) refuses the known ones, not every one, and compares paths, not folders:
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
  every capability (`--cap-drop ALL`), as it does for a normal user. A jail
  with `containers` is started differently (below).

Every tmux client `jail` starts (the liveness check and the attach) runs in a
sandbox of its own (`/nix`, `/etc`, the socket): a tmux server, jailed or a
fake one in the writable socket directory, can make a client run a command
(`detach-client -E`, `MSG_SHELL`).

## Containers

Why and the alternatives: [ADR 0007](adr/0007-jail-containers.md). Only for
a jail whose approved `.jail` has the line `containers` (`in_effect` then
ends in `| containers`); every other jail starts as above, the tree
`pasta -> jail-binds -> bwrap --unshare-all --share-net`.

- **User namespaces** (`jail-run`): `jail-userns` (also used by `jail
  reset`) makes U1, mapping your uid, gid and first `/etc/subuid` and
  `/etc/subgid` ranges to themselves through the host's setuid
  `newuidmap`/`newgidmap`, with every capability ambient there; in it a
  holder makes U2, a child with the same map (`unshare --map-users=all`,
  written by shadow's plain `newuidmap` with those capabilities). Each holder
  prints its PID once its map is written. Without a range it stops:
  `jail: no range for <user> in /etc/subuid ...`.
- **bwrap** runs on the host with `--userns` (U1, fd 6) and `--userns2` (U2,
  fd 7), `--unshare-ipc --unshare-pid --unshare-net --unshare-uts
  --unshare-cgroup-try`, `--cap-drop ALL --cap-add CAP_SETUID --cap-add
  CAP_SETGID`, `--info-fd` and `--block-fd`. Its namespaces are owned by U1;
  the jail's processes run in U2 with only those two capabilities (ambient,
  `no_new_privs` set, the bounding set full as a new user namespace's is),
  and none in U1: they cannot remount or unmount. `jail-run` closes every
  other fd before bwrap (pasta does that on the other path), and
  `jail-containers-init`, the jail's first command, closes 6 and 7.
- **Network:** with the child PID from the info fd, `jail-run` starts pasta
  with the same options as for every jail plus `--userns` (U1) and
  `--netns` (the child's); pasta sets the namespace up, goes to the
  background and quits when the namespace is gone. Then the holders are
  killed and bwrap is let go (block fd). A failure kills bwrap and names the
  step. A signal to `jail-run` goes to bwrap, whose child dies with it
  (`--die-with-parent`; bwrap has `jail-run`'s death as its own).
- **Inside:** `/dev/net/tun`; the jail's own cgroup (the shared jail's
  service, a one-off's scope) read-only at `/sys/fs/cgroup`; `/var/tmp` from `~/.local/share/jails/<name>/var-tmp`; at
  `/run/wrappers/bin`, first in `PATH` in every login shell (NixOS's
  `set-environment`) and in the start's `PATH`, podman, docker (with its
  compose and buildx plugins), docker-compose and shadow's plain
  `newuidmap`/`newgidmap`; `CONTAINERS_CONF`, `CONTAINERS_STORAGE_CONF`,
  `CONTAINERS_REGISTRIES_CONF`, `CONTAINERS_POLICY_JSON` (store files: overlay
  storage in `~/.cache/containers/storage`, `transient_store`,
  `docker.io` for short names, unsigned images accepted, `compose_providers`
  docker-compose), `DOCKER_HOST=unix:///run/user/<uid>/podman/podman.sock`,
  `DOCKER_BUILDKIT=0`.
- **API service:** `jail-containers-init` starts `podman system service
  --time=0` (log: `/run/user/<uid>/podman-service.log`), waits up to 10 s for
  its socket and runs the command. It is per instance (each has its own
  `/run/user`, PID namespace and transient container state) and dies with
  its PID namespace; the host has no podman socket.
- **cgroups:** every one-off jail (with `containers` or not) runs in a
  transient user scope, `jail-<name>-<pid>.scope` (`systemd-run --scope`,
  same process), the shared jail in `jail-<name>.service`, so a jail's
  cgroup is never the terminal's. With `containers`, `jail-run` refuses a
  cgroup that is `/` or not v2. The read-only bind is for podman to read,
  not a boundary: in a nested user and mount namespace jailed code can
  mount cgroup2 at its cgroup namespace's root, writable where your uid owns
  the files (as in every jail before), and make child cgroups of the jail's
  own, move its processes among them and set their limits, never above that
  root. Nothing is delegated for podman, whose default stays: `--memory`
  and the other limits fail (`crun: cannot set limits without cgroups`), as
  does BuildKit's builder container (hence `DOCKER_BUILDKIT=0`).
- **What the subuids give jailed code** (ADR 0007): it can `setresuid` and
  `setresgid` to any id of your ranges directly and create files owned by
  them, setuid and setgid ones included, wherever the host's files are bound
  read-write (repository, cache, `rw` paths); `no_new_privs` makes the bits
  harmless inside, and on the host (`/home` is not `nosuid`) such a file runs
  as one of your subuids, nothing more. Every container jail and your host's
  rootless containers share the one range: what one wrote as a subuid,
  another reaches as that id through any repository, `ro` or `rw` path they
  share. `setgroups` is allowed, so jailed code can drop its supplementary
  groups and pass files that deny access by group bits only.
- **Ports:** a published port is podman's (pasta's) listener in the jail's
  namespace; a `.jail` `port` forwards the host's `127.0.0.1` to it.
- **Cleanup:** what containers write as subuids (layers, volumes, files in
  the repository) is not yours on the host: `jail reset` (the cache and
  state, not the repository) runs `find` and `rm` inside `jail-userns`, where those ids are mapped and it has the
  capabilities; or `podman unshare rm` inside. `podman system prune
  --external` sees no other instance's containers (transient state) and
  deletes the layers they use.

## Windows VMs

Why and the alternatives: [ADR 0007](adr/0007-jail-containers.md), "Windows
VMs". winvm's code is in the store and `/dev/kvm` is in every jail already;
the jail decides only where its data is.

- **Every jail:** `WINVM_HOME=~/.cache/winvm` (`--setenv`, so it wins over
  a `~/.config/winvm/home` with the host's path, as home-manager writes it). On the host that is
  `~/.cache/jails/<name>/winvm`: outside the hourly `/home` snapshots, gone
  with `jail reset --all`, kept by `--home`. bwrap or winvm
  makes the directory: a plain one, not the btrfs subvolume with `chattr +C`
  winvm makes on the host (ADR 0006).
- **With `winvm`** (`with_winvm`, after the approved `.jail` is parsed): the
  host's home as winvm finds it (`$WINVM_HOME` of the `jail` call, else the
  first line of `${XDG_CONFIG_HOME:-~/.config}/winvm/home`, refused if not
  absolute, else `${XDG_DATA_HOME:-~/.local/share}/winvm`); of its
  `state/images`, `state/id_ed25519` and `state/id_ed25519.pub`, each that
  exists goes through `realpath -e` and `bind_path ... ro` (so not in the
  repository, the cache or the jails' state; a refusal stops the start:
  `jail: winvm: PATH: why`) and is bound read-only by fd (`jail-binds`
  `ro:DEST`) at the same name under the jail's `~/.cache/winvm/state`. The
  rest of the host's home (`vms`, `runs`, `captures`, `cache`, `iso`,
  `config.local.env`, `images/*.local.env`) is not in the jail. Without
  images on the host the line binds nothing. `in_effect` ends in `| winvm`.
- **Mount points:** bwrap leaves the empty `state/images`, `id_ed25519` and
  `.pub` it binds onto in the cache. A later start that binds nothing there
  (no line, no host key) leaves them: an empty key file that winvm takes as
  its key. Jailed code can replace them (or `state`) with links, which
  bwrap follows inside the jail: the images then appear where the link
  points, in the jail only, read-only as before. Both go with `jail reset
  --all` or by deleting `~/.cache/jails/<name>/winvm/state` (stopped jail).
- **winvm in a read-only images folder:** `build`, `commit` and `destroy
  --all` check that `state/images` (and the image's folder) is writable
  before they change anything and otherwise stop naming it. `build` also
  stops in any jail (`$JAIL` set): hours and ~20 GB per jail. Every other
  command writes only the VM's folder, `runs/` and `captures/` and reads the
  base image, `efivars.base.fd` and `tpm.base`; `winvm` writes the base
  images nowhere else.
- **Overlays:** a VM's `disk.qcow2` names its base by the jail-side path
  (`/home/<user>/.cache/winvm/state/images/<image>/base.qcow2`): it runs in
  that jail only. A host `build --force` or `commit` changes the base under
  it (the bind is the folder, not the file): `winvm reset` or a new VM.
- **Start:** QEMU (KVM, swtpm, user-mode network with `hostfwd` on
  `127.0.0.1`) needs nothing more. There is no PipeWire socket in the jail:
  `winvm start` then leaves out the audio device (`no PipeWire socket`)
  instead of QEMU refusing to start. No display: `--headless`, no `rdp` or
  `view` inside.
- **Ports:** SSH `2222` + slot, RDP `33890` + slot on the jail's
  `127.0.0.1`; the slot is fixed in `state/vms/<name>/slot` (0 for
  `default`, else the lowest free from 1). A `.jail` `port` forwards one to
  the host's `127.0.0.1`. A host VM in the same slot holds that port on the
  host: the shared jail does not start, a one-off skips the forward.
  `RDP_PORT`/`SSH_PORT` in the jail's `config.local.env` move the base.

## jail push

- `jail push [DIR] [ARGS...]` runs `jail-push DIR [ARGS...]`, the same
  code; both refuse inside a jail. A first argument that is a folder here
  and also a branch in the mirror of the current directory's jail is
  refused (`jail push ./NAME` or `jail push . NAME`), not guessed.

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
  refused), the first `jail push` shows `remote.origin.url`, which jailed code
  may have written, and pushes only after you type `yes` on a terminal.
  Allowed: `ssh://`, `https://`, `user@host:path`, or the absolute path of a
  bare repository (pushed through a sandboxed `git-receive-pack`, so its hooks
  run without network or home). To change it:
  `git --git-dir ~/.local/share/jails/<name>/mirror.git remote set-url origin <url>`.

## Managing jails

- State per jail: `~/.local/share/jails/<name>/` holds `home/`,
  `claude-plugin-data/`, `jail.approved`, `mirror.git/` (push URL),
  `resolv.conf`, `var-tmp/` (with `containers`) and `repo` (the repository's path, written by every start;
  jails last started before that have none and show `?` in `jail list`); the
  cache is `~/.cache/jails/<name>/`. The jail never sees this folder, so
  `jail list` and `jail status` trust what is in it; `repo` is used only when
  its path hashes to the folder's name.
- Running: a shared jail is the user unit `jail-<name>`
  (`systemctl --user is-active`). A one-off jail is a `jail-run` process
  (by `/proc/<pid>/comm`) outside a `jail-*.service` cgroup, named by the
  cache it binds (`rw:~/.cache ~/.cache/jails/<name>` in its arguments); it
  counts from its exec of `jail-run`, not while jail prepares it. Jailed
  code in a one-off jail can fake such a process, naming any jail: that
  makes `jail reset` of that or another jail refuse and inflates the counts
  in `jail list` and `jail status`, nothing more.
- A start holds a shared `flock` on `<name>/lock` from before its first
  step until its jail runs (a one-off: just before its exec of `jail-run`;
  the lock is closed for everything it starts), so a start still asking
  about `.jail` or preparing the home makes `jail reset` refuse.
- `jail status` counts the tmux clients through the same sandboxed client
  as a start (the server is jailed code) and prints only the count.
- `jail stop --all` stops the units of the jails in the state folder that
  are active, not every `jail-*` unit.
- `jail reset`: a `NAME` must be one path component (not `.` or `..`, no
  `/`) and a real directory directly in `~/.local/share/jails`, and no
  directory of that name in the current one; anything else is a `DIR`.
  It refuses while the shared or a one-off jail runs, lists the existing
  paths it deletes, needs `y` on a terminal (stdin and stderr), then takes
  the lock exclusively (refusing while a start holds it) and checks again
  that nothing runs, gives every folder in them `u+rwx` before `find`
  descends into it (folders read-only or made unreadable by jailed code;
  no links followed) and deletes them with `rm -rf`, both in `jail-userns`
  when you have a subuid range (files containers made as subuids).
- `jail list`, `jail status` and `jail config` print paths and URLs with
  control characters as text (`cat -vT`, a newline as `^J`), so a path
  cannot forge a row.
- The completion (`completions/jail.bash`, for zsh through
  `bashcompinit`): repository paths and mirror branches are chosen by
  jailed code, so they never go through `compgen -W` (which expands
  `$(...)`), only those needing no quoting are offered, and it runs no `cd`
  or git in a repository (zsh's `chpwd` hooks, direnv), only
  `git --git-dir=<mirror>`. `--all` also removes the recorded push
  URL: the next start records it again from the repository, which jailed
  code may have changed.

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
`.cache` in the jail home, and an old cache in the jail home stays, unused, with one
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
`jail push` pushes over ssh without running planted hooks, `core.fsmonitor`,
`core.sshCommand` (the global one runs) or `uploadpack.packObjectsHook`,
uses the URL `jail` recorded at its first start, asks on a terminal for an
unrecorded one and refuses without a terminal, keeps its stored URL (checked through the alias `jail-push`), refuses
`ext::` (allowed in the test's git config), `fd::`, `file://`, option-like and
non-repository URLs and URLs with control characters, a missing `DIR`, a
symlinked `.git`, a `.git/config` or `HEAD` that is a link to another
repository's or a FIFO, and an `include.path` to another repository's config, and runs a local remote's hooks
sandboxed; a container of worktrees (made with `git clone --bare`, a
`gitdir: ./.bare` file and `git worktree add`) has one jail, state and unit
from the container and from a worktree, git commits inside in each worktree,
the URL is recorded from the bare repository at the first start, `jail push`
from a worktree pushes only its branch (also from a relative-path worktree and
a subfolder), from the container or a folder outside the worktrees the bare
HEAD's, and from a worktree whose `.git` points elsewhere (another repository,
the bare repository itself, a `..` path out of it), whose git directory is a
FIFO (no wait) or whose `worktrees` is a link nothing without a named branch;
a container `.git` naming another repository, an absolute or `..` path, `./`,
a link, an empty directory or a FIFO instead of the bare repository, or a
FIFO as `.git` (no wait on either) is refused by `jail` and `jail push`, from the container and
from a worktree; a linked worktree and a submodule of a normal repository use
its jail, and `jail push` from the worktree pushes the repository's HEAD;
two terminals share
one tmux server and one unit, the shell in it is jailed, and a
`detach-client -E` command does not run on the host, the shared jail reaches
the Notifications stand-in and the second node and starts again after a stop;
every start writes `repo`; `jail list` shows a shared jail and a one-off one
running, `.jail` none, pending and approved, the push URL, sizes, `?` for a
jail without `repo` and `(gone)` for a removed repository; folders named
`list`, `status`, `stop`, `reset`, `push`, `help`, `config` open as
`./NAME` while the words stay commands; `jail help` (= `--help`) groups the
commands; `jail status` shows config, running, unit, tmux clients, state,
cache and push URL and writes nothing; `jail stop` by `DIR` and `NAME`, and
`--all`; `jail reset` without a flag, while the shared or a one-off jail
runs and without a terminal refuses, after `n` deletes nothing, after `y`
deletes exactly the listed paths (`--home` keeps `mirror.git`, also with
read-only folders), by `NAME` for a gone repository and a dotted name, and
takes a folder of the name here as `DIR`; `jail push` from the current
directory; the host commands and `jail-push` refuse inside a jail; bash
completion of commands, folders, jail names, flags and `jail push` /
`jail-push` repositories and mirror branches; `jail reset` refuses after
its `y` when a one-off started meanwhile and while a start asks about
`.jail`, deletes a mode-000 folder in the jail home, and a bad `NAME`
lists nothing; `jail push` refuses a folder that is also a branch; a path
with a newline shows as `^J` in `jail list` and `jail status`; a mirror
branch and a repository path with `$(...)` run nothing in bash and zsh
completion, a normal branch completes, and zsh runs no `chpwd`;
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
jails' state, `~/.cache`, `~/.cache/jails`, a folder in each, `/etc`, `/nix/store`, `/run/user`, `/proc`, `/tmp`, the
repository and its `.git`, `~/.ssh`, `~/.gnupg`, `~/.claude` and below it,
`~/.codex`, `~/.claude.json`, keyrings, `~/.password-store`, and as `rw`
`~/.config`, `~/.local/state`, `~/.local/bin`, `~/brain`), relative and
missing paths, ports below 1024 or above 65535 and unknown keywords are
refused with the line named, and nothing is applied; the approval shows a tab
as `^I` and the line with what is in effect;
`jail --help` names the README path, and the README is there inside a jail;
`jail config` on the host for a repository without a jail reports the
`.jail` and creates no state or cache, and for an approved one shows what it
would add and the approved copy and changes nothing in the state; inside a
one-off jail it shows what it would add, what is in effect in this jail and
which checks it skipped, reports a `.jail` edited inside as differing, with
how to apply it (also on the host), and an empty `.jail` against a
non-empty approved copy as differing, names a bad line with exit status 1
(also on the host), a linked `.jail` and a path with `..`, gives a nested
repository no "in effect", and leaves `jail.approved` as it was; in the
shared jail a shell sees what is in effect; a `.jail` over 64 KiB, a FIFO
(no wait) or a directory is not applied; an approved path that is gone stops
the start; `jail-binds` refuses a bind source that is a link when it opens
it (a swap after the check) and the jail holds no fd beyond 0 to 2
(a fake server answering
the liveness check is covered by construction, the same sandbox, not by a
test). Every negative check has
a positive control outside the jail.

Windows VMs (a fake host home `~/winvm-host`, named by
`~/.config/winvm/home`, with a 16 MiB qcow2 as `win10`'s base, a dummy key
and a host VM): every jail's `WINVM_HOME` and `winvm home` are
`~/.cache/winvm`, without the line it is empty there and `winvm list` sees
no VMs; `jail config` and the start show `| winvm`; with it the base image
and both key files are readable, and creating, appending, replacing,
removing and `chmod` there fail; the host VM and `~/winvm-host` are not
visible; `winvm images` sees the build, `winvm new` makes a VM whose disk's
backing file is the jail-side path, in `~/.cache/jails/<name>/winvm`;
`winvm build` stops with `read-only here`; swtpm starts; with KVM, `winvm
start --headless` runs the VM without audio, its SSH and RDP forwards on
the jail's `127.0.0.1`, and `stop --force` ends it; `destroy` removes it;
the host home is unchanged (`find -printf` of names, sizes, times, modes
before and after); a stand-in RDP listener on the jail's `127.0.0.1:33891`
is reached from the host through `port 33891`; the host home comes from
`WINVM_HOME`, else the config file, else `~/.local/share/winvm`; a host
home without images binds nothing (the jail's `state/images` is empty and
writable) and `winvm build` still stops (`not in a jail`); one in the
repository is refused; a repository under `/tmp` gets a jail.

Containers (the end of the test, `localhost/jailtest`, a busybox image built
by `dockerTools` and loaded with `podman load`, offline): a jail without the
line has no `/dev/net/tun`, podman, docker, `DOCKER_HOST` or API process;
`jail config` and the start show `| containers`; a user without a subuid
range is refused by name, on the terminal, for a one-off and a shared
start alike; the plain jail has no `/sys/fs/cgroup` and a one-line uid map;
the containers jail reaches the outside but not the host's loopback or the
gateway; a one-off runs in its own `jail-<name>-<pid>.scope`; the jail's capabilities are exactly
`CAP_SETUID`/`CAP_SETGID` with `no_new_privs`, and it holds no fd beyond 0
to 2; podman's map has the subuid range, a container `chown`s to 4321
(104320 on the host), `su`s to nobody and runs as `--user 4321`; `--memory`
fails; `docker network create`, two containers by name, `docker ps` and
`docker build` through the socket; a container with the socket mounted
at `/var/run/docker.sock` lists the containers through it (what
testcontainers' Ryuk does); `podman unshare rm` deletes a folder a
container made private as a subuid, which your `rm` cannot; `docker compose up` with two services
(one reaching the other by name), its published port reached in the jail
and from the host through `port`, `podman compose ps`; no podman socket on
the host; service, containers, pasta and holders gone after the jail ends,
also by SIGKILL; in the shared jail's login shell `podman`, `docker` and
`newuidmap` resolve to `/run/wrappers/bin`, and a one-off next to it sees
none of its containers; `jail reset --all` deletes a volume folder owned
by a subuid with mode 0700, which your own `rm -rf` cannot.

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
- Home-manager's files under `~/.cache` are linked into the jail home's
  `.cache`, which the cache bind hides: they are not in the jail's
  `~/.cache` (home-manager puts only `.keep` files there).
- Home-manager's files are linked when a jail starts; after a switch, restart
  the jail to pick them up.
- A tmux server with the jail stays alive while a window is open, also with no
  terminal attached.
