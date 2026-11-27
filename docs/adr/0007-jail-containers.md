# 0007: Containers inside a jail: the jail's own rootless podman, many uids; Windows VMs on the host's base images

Date: 2026-11-27. Status: accepted, implemented in `pkgs/jail`
([docs/jail.md](../jail.md), Containers and Windows VMs).

## Context

Agents and builds in a repository jail (ADR 0001) need containers:
`docker run`, `docker compose`, a database for tests, `docker build`. The
host's Docker or Podman socket is root-equivalent or at least reaches
everything of yours, so it is never given to a jail (goal G-12). A jail
drops every capability and has one uid, which is not enough for real images
(postgres, nginx and `apk add` switch to their own users).

## Options

1. The host's docker or podman socket in the jail: refused (above).
2. Podman inside the jail with one uid (`ignore_chown_errors`): runs busybox,
   fails for images that `chown` or switch users (nginx, postgres, redis,
   `RUN adduser`).
3. Podman inside the jail with your subuid range: needs a user namespace in
   which podman can write a multi-line uid map, and the jail must still not
   hold a capability over its own mounts (it could remount a read-only bind
   read-write).
4. A VM per jail: heavy, and the jail's files would cross a VM boundary.

## Decision

Decided by the user (goal G-12): containers in the jail without a host
daemon, opt-in per repository, real Compose against the jail's own API.
Design decided by the agent, option 3:

- **Opt-in:** a `.jail` line `containers`, approved like ports and folders,
  shown in `jail config` and `jail status`. Without it the jail is started
  exactly as before.
- **Two user namespaces** (`jail-run`). U1 maps your uid and gid and your
  `/etc/subuid` and `/etc/subgid` ranges to themselves (written by the host's
  setuid `newuidmap`/`newgidmap`, which allow only those ranges); it owns the
  jail's mount, PID, network, IPC and UTS namespaces. U2 is a child of U1
  with the same map; the jail's processes live there. bwrap gets both
  (`--userns`, `--userns2`), drops every capability but `CAP_SETUID` and
  `CAP_SETGID` (ambient, in U2 only) and sets `no_new_privs`. Those two let
  podman's `newuidmap` (shadow's plain binary, first in `PATH`) map its own
  namespace from the same ranges, as rootless podman does on a host. In U1,
  which owns the mounts, the jail has no capability: it cannot remount,
  unmount or bind anything.
- **Network:** bwrap makes the network namespace, pasta attaches to it
  afterwards (through U1) with the same options as for every jail; a `.jail`
  port forward reaches a port a container publishes in the jail.
- **Devices and cgroups:** `/dev/net/tun` (pasta for container networks).
  Every one-off jail runs in a transient user scope of its own
  (`jail-<name>-<pid>.scope`), the shared jail in its service, so the jail's
  cgroup is never the terminal's; a jail with `containers` whose cgroup is
  the root, or not cgroup v2, is refused. That cgroup is bound read-only at
  `/sys/fs/cgroup` (with a cgroup namespace it is the root) for podman to
  read. The read-only bind is not the boundary: in a nested user and mount
  namespace (podman's, or one jailed code makes) cgroup2 can be mounted at
  the cgroup namespace's root, writable where your uid owns the files, as in
  every jail before this change. Jailed code can then make child cgroups of
  the jail's own, move its processes between them and set limits on them,
  never above the namespace root, and never on the terminal's or other
  cgroups. Nothing is delegated for podman: `--memory`, `--cpus` and
  BuildKit's builder fail loudly, podman's default.
- **The API:** every jail instance (the shared one, each one-off) starts its
  own `podman system service` at `$XDG_RUNTIME_DIR/podman/podman.sock`,
  inside the jail's own `/run/user/<uid>`, in its PID namespace (it ends with
  the jail). `DOCKER_HOST` points there; `docker` is the real docker client
  with its Compose v2 plugin (`DOCKER_BUILDKIT=0`: podman builds), and
  `podman compose` runs the same docker-compose. The socket is podman's own,
  rootless, inside the jail: never the host's.
- **Storage:** overlay in the jail's `~/.cache/containers/storage` (the jail's
  own cache), `transient_store = true`, so containers' and pods' state lives
  in each instance's `/run/user` and one instance never sees another's
  containers; images, volumes and networks are in the cache, shared by the
  jail's instances. `/var/tmp` (image layers being unpacked) is
  `~/.local/share/jails/<name>/var-tmp`, outside the jail's reach as a mount
  source.

## Consequences

- The jail holds `CAP_SETUID` and `CAP_SETGID` in its own user namespace and
  a full bounding set (podman's namespaces need it). Jailed code, not only
  podman, can `setresuid`/`setresgid` to any id of your subuid and subgid
  ranges (100000 and up) directly. It can create files owned by those ids,
  setuid and setgid ones included, in every place bound read-write from the
  host: the repository, the jail's cache, `rw` paths. Inside, `no_new_privs`
  keeps the bits and file capabilities from raising anything. On the host,
  `/home` is not `nosuid`; a setuid file of a subuid gives you nothing you
  could not do already (those ids are yours through `newuidmap`), but it is
  a setuid file another user could run if its folder lets them.
- All jails with `containers`, and your rootless containers on the host,
  share the one range. Whatever one of them wrote as a subuid is readable
  and writable, as that id, by every other through a path they share: the
  repository, a `ro` or `rw` path. The range separates you from other
  users, not your jails from each other.
- `setgroups` is allowed in the jail's user namespaces (podman needs it), so
  jailed code can drop its supplementary groups and get past a file that
  denies access by its group bits (mode `0604`, say) where the other bits
  allow it.
- Your own `rm` cannot delete what a container made private as a subuid:
  `podman unshare rm` inside, or `jail reset` (its cache and state, not the
  repository), which deletes in a user namespace with those ranges.
- Without a subuid range (`users.users.<name>.autoSubUidGidRange`, on by
  default for normal users) a jail with `containers` refuses to start and
  says so; `jail reset` then works as before.
- Storage cleanup: `jail reset --all` or podman inside (`podman system prune`,
  `podman volume prune`). `podman system prune --external` also deletes
  layers that another running instance of the same jail uses.
- `podman volume ls` in a new instance does not list volumes made before
  (their records are transient), but a volume of the same name finds its data
  again.
- `/run/wrappers/bin` in such a jail holds podman, docker, docker-compose and
  the plain `newuidmap`/`newgidmap`, not setuid wrappers.

Decided by: user (goal G-12: containers without a host daemon, opt-in, the
jail's own API socket, real Compose); agent (design: two user namespaces,
subuids, the cgroup view, per-instance service and storage).

## Windows VMs

### Context

winvm (`pkgs/winvm`, ADR 0006) is plain QEMU/KVM: its code is in the store
and `/dev/kvm` is in every jail, so only its data decides what a jail can
do. A base image takes hours to build and ~20 GB; a jail should run VMs on
the host's builds (goal G-12: "Share base images read-only") without
reaching the host's VMs or writing the host's `WINVM_HOME`. Inside, winvm
would take the host's path from `~/.config/winvm/home` (home-manager).

### Options

1. The jail's own `WINVM_HOME` in its cache, with the host's `state/images`
   and the key bound read-only into it (`.jail` line `winvm`).
2. The same, in the jail home (`~/.local/share/winvm`): in the hourly
   `/home` snapshots, which would keep multi-GB overlays for weeks.
3. The host's `WINVM_HOME` read-write: the host's VMs, runs and base
   images writable by jailed code.
4. Builds in the jail: hours per jail and repository, ~20 GB each.

### Decision

Option 1. Every jail gets `WINVM_HOME=~/.cache/winvm` (outside the `/home`
snapshots, like podman's storage); with `winvm` in the approved `.jail`, the
host's `state/images`, `state/id_ed25519` and `.pub` (from where winvm on
the host finds its home) are bound read-only at the same names there, by fd
and through `bind_path`, as `ro` lines are. winvm checks before `build`,
`commit` and `destroy --all` that the images are writable, refuses `build`
in any jail, and starts without audio when there is no PipeWire socket.

### Consequences

- The jail reads everything in the images folder: the base images, the
  answer files with the Windows user's password (`unattend/`,
  `unattend.iso`), the swtpm CA's signing key (`tpm-ca`), the build logs,
  and the private key every VM built from these images trusts. Whoever runs
  in the jail can log in to each such VM it reaches. The host's VMs listen
  on the host's `127.0.0.1` only, which a jail does not reach (the jail VM
  test); a `.jail` `port` forwards the other way only.
- A host `build --force` or `commit` changes the base under the jails' VMs:
  their overlays then need `winvm reset` or a new VM. An overlay names its
  base by the jail-side path, so a jail's VM runs in that jail only.
- The jail's VMs go with `jail reset --all`. Its `WINVM_HOME` is a plain
  directory with the line (bwrap's mount points), else winvm's btrfs
  subvolume; `rm -rf` removes either.
- The host's `WINVM_HOME` must not be in a repository you jail: that jail
  could write the images and the key, so `jail` refuses it.
- The key (and the rest of the images folder) can leave the machine over
  the jail's outbound network, like anything else the jail reads.
- No sound, no display: `--headless`; RDP from the host through a `.jail`
  `port` (the VM's slot is fixed, so the port is too).
- A host VM in the same slot holds that port on the host, and the shared
  jail does not start until `RDP_PORT` moves the jail's base.

Decided by: user (goal G-12: winvm in a jail, base images and key shared
read-only, VMs the jail's own); agent (design: the cache as `WINVM_HOME`,
for every jail; the binds; winvm's checks and the audio fallback).
