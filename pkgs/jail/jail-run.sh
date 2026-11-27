bus=$1
tcp=(-t none)
[ -z "$2" ] || tcp=(--host-lo-to-ns-lo -t "127.0.0.1/$2")
shift 2
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
# host's nameserver. Inside pasta's user namespace we are root: bwrap
# maps back to our ids and drops every capability, as it does when
# started by a normal user. Not exec: the proxy's pipe must stay open.
# pasta dies with this script, even by SIGKILL (pdeathsig); the outer env
# resets SIGINT, ignored in a background job (nohup's HUP stays ignored),
# the inner one every signal for the jailed program (pasta ignores SIGPIPE).
setpriv --pdeathsig KILL env --default-signal=INT \
  pasta --config-net --quiet "${tcp[@]}" -u none -T none -U none --no-map-gw --dns-forward 169.254.1.1 \
  -- env --default-signal @jailBinds@/bin/jail-binds "${binds[@]}" -- @bubblewrap@/bin/bwrap --uid "$(id -u)" --gid "$(id -g)" --cap-drop ALL "$@" <&0 &
pid=$!
# A signal to this script (kill, systemctl stop) goes on to pasta, whose
# death ends bwrap (--die-with-parent); then it is raised here again.
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
