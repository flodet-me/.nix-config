# Goals

Open goals only (factory skill: goal, Accept lines, items, status). A goal
leaves this file in the commit that finishes it (`factory: G-<n> done`), so
the finished ones are in git history:

```sh
git log --oneline -- docs/goals.md          # every goal, item and done commit
git show fc929d4:docs/goals.md              # G-1 to G-6, the last full version
git log -p --grep 'G-<n>' -- docs/goals.md  # one goal's history
```


## G-12 Windows VMs and container networks inside a jail  (status: open)

Goal: "spawn a windows vm in a jail and then please also create networks with
docker or more to test everything works and I could alos develop network apps."
Accept:
- A `.jail` line (approved like ports and folders) lets winvm run inside the
  jail: WINVM_HOME is the jail's own, the host's built base images and the SSH
  key they trust are bound read-only (user's choice: "Share base images
  read-only"); VMs, snapshots and runs live in the jail. The jail cannot write
  anything in the host's WINVM_HOME.
- In a throwaway repository's jail on desktop, `winvm new`, `start --headless
  --wait`, `ssh`, `stop`, `destroy` work, and `tests/smoke.sh` passes there;
  the throwaway jail is reset afterwards.
- RDP from the host reaches a jailed VM through a `.jail` port forward
  (documented; GUI viewers do not run inside, there is no display).
- Containers inside the jail without a host daemon: `docker` (podman's
  docker CLI) runs images, `docker network create` gives a network on which
  two containers reach each other by name, `docker compose` works, and a
  container port reaches the jail (and the host through a `.jail` forward).
  The host's docker/podman socket is never given to a jail. Each container
  jail starts its own podman API service (DOCKER_HOST set), so Docker's
  Compose v2 and testcontainers work; it stops with the jail.
- A jail VM test covers the container part (two containers on a user network,
  name resolution, a published port); the winvm part has a VM test of the
  binds and home, and the desktop run above.
- ADR 0007 (what the jail gains: e.g. /dev/net/tun, any /sys access, the
  shared key's reach), README and docs/jail.md; ADR 0001 status updated
  (winvm binds were "not planned").
- Check (`-- --jail`) and Gate green.
Not in scope: GUI inside the jail, rootful containers, the host's docker.
Assumptions: rootless podman as the engine (a host docker socket would make
the jail root-equivalent); the throwaway repository and its jail state may be
created and reset on desktop.

| Item | What | Status | Commit |
|---|---|---|---|
| I1 jail-containers | rootless podman, docker CLI, networks, compose, VM test, ADR | open | |
| I2 jail-winvm | .jail winvm line, ro base images and key, desktop run | open | |
