[ $# -eq 2 ] || { echo "usage: jail-git-sandbox git-upload-pack|git-receive-pack PATH" >&2; exit 2; }
case $1 in
  git-upload-pack) bind=--ro-bind-fd ;;
  git-receive-pack) bind=--bind-fd ;;
  *) echo "jail-git-sandbox: unknown command $1" >&2; exit 2 ;;
esac
exec 3<"$2"
[ "$(readlink /proc/self/fd/3)" = "$2" ] || { echo "jail-git-sandbox: $2 is not a plain directory path" >&2; exit 1; }
proto=()
[ -z "${GIT_PROTOCOL:-}" ] || proto=(--setenv GIT_PROTOCOL "$GIT_PROTOCOL")
exec bwrap --unshare-all --die-with-parent --new-session --clearenv \
  --ro-bind /nix /nix --ro-bind-try /bin /bin --ro-bind-try /usr /usr \
  --proc /proc --dev /dev --tmpfs /tmp "$bind" 3 "$2" \
  --setenv PATH @git@/bin --setenv HOME /tmp --setenv GIT_CONFIG_NOSYSTEM 1 \
  "${proto[@]}" -- git "${1#git-}" "$2"
