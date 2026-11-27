# 0007: Containers inside a jail: the jail's own rootless podman, many uids

Date: 2026-11-27. Status: accepted, implemented in `pkgs/jail`
([docs/jail.md](../jail.md), Containers).

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
- **Devices and cgroups:** `/dev/net/tun` (pasta for container networks);
  the jail's own cgroup bound read-only at `/sys/fs/cgroup` (with a cgroup
  namespace it is the root). Nothing is delegated: `--memory`, `--cpus` and
  BuildKit's builder fail loudly, podman's default, rather than escaping the
  jail's cgroup.
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
  a full bounding set (podman's namespaces need it; `no_new_privs` keeps
  setuid files and file capabilities from raising anything). It can act as
  any uid of your subuid range: files owned by 100000 and up appear in the
  repository, the cache and `rw` paths, and your own `rm` cannot delete what
  a container made private (`podman unshare rm`, or `jail reset`, which
  deletes in a user namespace with those ranges). Your subuids are the same
  ones your host's rootless containers use; their files are not in the jail.
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
