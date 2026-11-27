bus=$1 containers=$3
tcp=(-t none)
[ -z "$2" ] || tcp=(--host-lo-to-ns-lo -t "127.0.0.1/$2")
shift 3
binds=()
while [ $# -ge 2 ] && [ "$1" != -- ]; do binds+=("$1" "$2"); shift 2; done
[ "${1:-}" = -- ] || { echo "jail-run: no -- after the binds" >&2; exit 2; }
shift
# the proxy leaves its socket behind when stopped by a signal
cleanup() { [ -z "$bus" ] || rm -f "$bus"; }
trap cleanup EXIT
if [ -n "$bus" ]; then
  rm -f "$bus"
  # The proxy stops when the pipe's read end closes: it is held here only
  # (pasta closes inherited fds), so the proxy ends with this script.
  exec {ready}< <(exec xdg-dbus-proxy --fd=1 "unix:path=${XDG_RUNTIME_DIR:?}/bus" "$bus" \
    --filter --talk=org.freedesktop.Notifications)
  read -r -N1 -t 10 -u "$ready" _ || { echo "jail: starting the D-Bus proxy failed" >&2; exit 1; }
fi
# Only PORTS forwarded into the namespace (host 127.0.0.1 to its
# 127.0.0.1), nothing out to the host's ports, the host's loopback not
# mapped to the gateway; DNS goes to pasta's
# forwarder at 169.254.1.1 (the jail's resolv.conf), which asks the
# host's nameserver.
net=(--config-net --quiet "${tcp[@]}" -u none -T none -U none --no-map-gw --dns-forward 169.254.1.1)
if [ -z "$containers" ]; then
  # Inside pasta's user namespace we are root: bwrap
  # maps back to our ids and drops every capability, as it does when
  # started by a normal user. Not exec: the proxy's pipe must stay open.
  # pasta dies with this script, even by SIGKILL (pdeathsig); the outer env
  # resets SIGINT, ignored in a background job (nohup's HUP stays ignored),
  # the inner one every signal for the jailed program (pasta ignores SIGPIPE).
  setpriv --pdeathsig KILL env --default-signal=INT \
    pasta "${net[@]}" -- env --default-signal @jailBinds@/bin/jail-binds "${binds[@]}" -- \
    @bubblewrap@/bin/bwrap --unshare-all --share-net --uid "$(id -u)" --gid "$(id -g)" --cap-drop ALL "$@" <&0 &
  pid=$!
else
  # Containers (docs/jail.md, ADR 0007). Two user namespaces with your uid,
  # gid and subuid/subgid ranges mapped to themselves: U1, made here by the
  # host's setuid newuidmap, owns the jail's other namespaces; U2, its child
  # with the same map, holds the jail's processes. In U2 they keep only
  # CAP_SETUID and CAP_SETGID, which podman's newuidmap (a plain one, not
  # setuid) needs; in U1, which owns the mounts, they have none.
  # Holders keep both alive until bwrap and pasta have joined them; each
  # prints its PID once its maps are written.
  # shellcheck disable=SC2016 # expanded by the holder's shell
  hold='echo $$; PATH=$1:$PATH setpriv --pdeathsig KILL unshare --user --map-users=all --map-groups=all -- "$0" -c "echo \$\$; exec sleep infinity" & wait'
  exec {h}< <(exec setpriv --pdeathsig KILL @jailUserns@/bin/jail-userns "$BASH" -c "$hold" "$BASH" @idmap@/bin)
  if ! read -r -t 10 -u "$h" h1 || ! read -r -t 10 -u "$h" h2; then
    echo "jail: making the user namespaces for containers failed" >&2
    exit 1
  fi
  exec 6</proc/"$h1"/ns/user 7</proc/"$h2"/ns/user
  # bwrap's child PID through a pipe only bwrap writes (EOF if it fails);
  # bwrap waits for a byte on the block fd until pasta has attached
  exec {iw}<> <(:)
  exec {info}</proc/self/fd/"$iw" {blk}<> <(:)
  # the jail's own cgroup as /sys/fs/cgroup, read-only: podman reads it
  # (its cgroup namespace makes it the root); none when it is /
  cg=() line=""
  while IFS= read -r line; do [[ $line != 0::/?* ]] || cg=(--ro-bind "/sys/fs/cgroup${line#0::}" /sys/fs/cgroup); done </proc/self/cgroup
  (
    # no fd but these for the jail (pasta closes them on the other path)
    for f in /proc/self/fd/*; do
      f=${f##*/}
      case $f in 0 | 1 | 2 | 6 | 7 | "$iw" | "$blk") ;; *) exec {f}<&- 2>/dev/null || true ;; esac
    done
    exec setpriv --pdeathsig KILL env --default-signal @jailBinds@/bin/jail-binds "${binds[@]}" -- \
      @bubblewrap@/bin/bwrap --userns 6 --userns2 7 --info-fd "$iw" --block-fd "$blk" \
      --unshare-ipc --unshare-pid --unshare-net --unshare-uts --unshare-cgroup-try "${cg[@]}" \
      --uid "$(id -u)" --gid "$(id -g)" --cap-drop ALL --cap-add CAP_SETUID --cap-add CAP_SETGID "$@"
  ) <&0 &
  pid=$!
  exec {iw}<&-
  child=""
  while [ -z "$child" ] && IFS= read -r -t 10 -u "$info" line; do
    [[ ! $line =~ \"child-pid\":\ *([0-9]+) ]] || child=${BASH_REMATCH[1]}
  done
  # pasta joins U1 (it owns the network namespace), sets the network up and
  # goes to the background; it ends when the namespace does
  if [ -z "$child" ] || ! pasta "${net[@]}" --userns /proc/"$h1"/ns/user --netns /proc/"$child"/ns/net; then
    kill "$pid" 2>/dev/null || true
    echo "jail: $([ -n "$child" ] && echo "setting up the jail's network (pasta)" || echo "starting bwrap") failed" >&2
    exit 1
  fi
  kill "$h2" "$h1" 2>/dev/null || true
  exec 6<&- 7<&- {h}<&- {info}<&-
  echo >&"$blk"
  exec {blk}<&-
fi
# A signal to this script (kill, systemctl stop) goes on to pasta, whose
# death ends bwrap (--die-with-parent), or with containers to bwrap
# itself; then it is raised here again.
sig=
for s in TERM INT HUP; do
  # shellcheck disable=SC2064 # $s now, $pid is set
  trap "sig=$s; kill -$s $pid 2>/dev/null || true" "$s"
done
rc=0
wait "$pid" || rc=$?
while kill -0 "$pid" 2>/dev/null; do rc=0; wait "$pid" || rc=$?; done
if [ -n "$sig" ]; then
  cleanup
  trap - EXIT "$sig"
  kill -"$sig" $$
fi
exit "$rc"
