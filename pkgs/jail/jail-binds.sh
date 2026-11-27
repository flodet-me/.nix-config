specs=()
while [ $# -ge 2 ] && [ "$1" != -- ]; do
  case $1 in ro) b=--ro-bind-fd ;; rw) b=--bind-fd ;; *) echo "jail-binds: unknown kind $1" >&2; exit 2 ;; esac
  exec {fd}<"$2" || { echo "jail: cannot open $2" >&2; exit 1; }
  f=/proc/self/fd/$fd
  if [ "$(readlink "$f")" != "$2" ] || { [ ! -d "$f" ] && [ ! -f "$f" ]; }; then
    echo "jail: $2 changed after it was checked (a link?); not started" >&2
    exit 1
  fi
  specs+=("$b" "$fd" "$2")
  shift 2
done
[ "${1:-}" = -- ] || { echo "usage: jail-binds [ro|rw PATH]... -- BWRAP..." >&2; exit 2; }
shift
if [ ${#specs[@]} -gt 0 ]; then exec 5< <(printf '%s\0' "${specs[@]}"); else exec 5</dev/null; fi
exec "$@"
