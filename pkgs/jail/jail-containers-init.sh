# The first process of a jail with containers (inside it): closes the user
# namespace fds bwrap leaves open (jail-run's --userns 6 --userns2 7),
# starts the jail's own podman API service (DOCKER_HOST) and runs CMD.
# The service lives in the jail's PID namespace: it ends with the jail.
# Args: CMD...
exec 6<&- 7<&-
sock=${XDG_RUNTIME_DIR:?}/podman/podman.sock
log=$XDG_RUNTIME_DIR/podman-service.log
# at its default socket, $sock (it makes the folder)
@podman@/bin/podman system service --time=0 </dev/null >"$log" 2>&1 &
for _ in $(@coreutils@/bin/seq 100); do [ ! -S "$sock" ] || break; @coreutils@/bin/sleep 0.1; done
[ -S "$sock" ] || echo "jail: the podman API service did not start (see $log)" >&2
exec "$@"
