usage="usage: jail [DIR] [-- CMD...]"
dir=$PWD
if [ $# -gt 0 ] && [ "$1" != -- ]; then
  case $1 in -h | --help) echo "$usage"; exit 0 ;; esac
  dir=$1
  shift
fi
if [ $# -gt 0 ]; then
  [ "$1" = -- ] && [ $# -gt 1 ] || die "$usage"
  shift
fi

resolve "$dir"
cwd=$(cd "$dir" && pwd -P)
case $HOME in /home/?*) ;; *) die "HOME must be under /home: $HOME" ;; esac
case "$HOME/" in "$root"/*) die "$root contains your home directory" ;; esac
run=${XDG_RUNTIME_DIR:?jail: XDG_RUNTIME_DIR is not set}
user=$(id -un)
name=$(jail_name "$root")
state=$HOME/.local/share/jails/$name
jhome=$state/home
if [ ! -e "$state" ]; then
  # First start: no jailed code has run for this repository yet, so its
  # push URL is still yours. Later ones jail-push asks you to confirm.
  if open_gitdir "$gitdir" && url=$(origin_url) && valid_url "$url"; then
    store_url "$state/mirror.git" "$url" || die "cannot store the push URL in $state/mirror.git"
    printf 'jail: jail-push %s pushes to %q\n' "$root" "$url"
  else
    echo "jail: no push URL recorded for $root (none, or refused: $bad_url); jail-push asks on first use" >&2
  fi
  exec 3<&-
fi
mkdir -p "$jhome"
# The jail's ~/.cache, outside the /home snapshots (~/.cache is a subvolume
# of its own). Before, it was in the jail home: that one stays, unused.
cache=$HOME/.cache/jails/$name
if [ ! -e "$cache" ] && [ -d "$jhome/.cache" ] && [ ! -L "$jhome/.cache" ]; then
  echo "jail: the jail's cache is now $cache; the old one, $jhome/.cache, is no longer used (delete it while the jail is stopped)" >&2
fi
mkdir -p "$cache" || die "cannot create $cache"

# On every start: dotfiles, mount points, ~/.claude.json (prepareHome).
prepare() {
  local gen=$HOME/.local/state/home-manager/gcroots/current-home files host=()
  files=$(readlink -f "$gen/home-files") && [ -d "$files" ] ||
    die "no home-manager generation at $gen (home-manager not activated yet?)"
  vars=$(readlink -f "$gen/home-path/etc/profile.d/hm-session-vars.sh") && [ -f "$vars" ] ||
    die "no hm-session-vars.sh in the home-manager generation at $gen"
  [ ! -f "$HOME/.claude.json" ] || host=(--ro-bind "$HOME/.claude.json" /tmp/host.json)
  bwrap --unshare-all --die-with-parent --clearenv --ro-bind /nix /nix \
    --proc /proc --dev /dev --tmpfs /tmp "${host[@]}" --bind "$jhome" /tmp/home \
    -- @prepareHome@/bin/jail-prepare-home "$files" "${mounts[@]#"$HOME"/}" ||
    die "could not prepare $jhome; to start over, reset its home (docs/jail.md, Reset)"
}

# jail-run's pasta namespace: --share-net keeps it
args=(
  --unshare-all --share-net --die-with-parent --new-session --clearenv
  --ro-bind /nix /nix
  --bind /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket
  --ro-bind /etc /etc
  --ro-bind-try /bin /bin
  --ro-bind-try /usr /usr
  --ro-bind-try /lib64 /lib64
  --ro-bind-try /run/current-system /run/current-system
  --proc /proc
  --dev /dev
  --dev-bind-try /dev/kvm /dev/kvm
  --tmpfs /tmp
  --perms 0700 --tmpfs "$run"
  --tmpfs /home
  --bind "$jhome" "$HOME"
)
# same path inside, only if it exists
bind() { [ -e "$2" ] && args+=("$1" "$2" "$2") || true; }
bind --ro-bind "$HOME/brain"
bind --bind "$HOME/brain/inbox"
# ~/.claude, ~/.codex: the jail's own directories, so state, temp files
# and new names stay in the jail; host entries on top (see the patterns).
host_entries() {
  local e n
  for e in "$HOME/$1"/* "$HOME/$1"/.*; do
    n=${e##*/}
    [ -e "$e" ] && [ "$n" != . ] && [ "$n" != .. ] || continue
    if [[ $n == @($2) ]]; then args+=(--bind "$e" "$e")
    elif [[ $n != @($3) ]]; then args+=(--ro-bind "$e" "$e")
    else continue; fi
    mounts+=("$e")
  done
}
mounts=()
host_entries .claude '@claudeShared@' '@claudeState@'
host_entries .codex '@codexShared@' '@codexState@'
# plugin state, where plugins also install their dependencies: per jail
if [ -d "$HOME/.claude/plugins/data" ]; then
  mkdir -p "$state/claude-plugin-data"
  args+=(--bind "$state/claude-plugin-data" "$HOME/.claude/plugins/data")
fi
bind --ro-bind "$HOME/.local/bin" # graphify
bind --ro-bind "$HOME/.local/share/uv/tools" # its venv
# the repository, the cache and .jail's paths: opened and checked by jail-binds, bound by fd here
fdbinds=(rw "$root" "rw:$HOME/.cache" "$cache")
mounts+=("$HOME/.cache")
args+=(--args 5 --chdir "$cwd")
# DNS through pasta (jail-run): the host's resolv.conf (it may name
# 127.0.0.53) with only its search and options lines. Written outside
# the jail's reach and replaced whole, a running jail keeps its copy.
if [ -e /etc/resolv.conf ]; then
  if ! { { grep -E '^(search|domain|options)([[:space:]]|$)' /etc/resolv.conf || true; echo "nameserver 169.254.1.1"; } >"$state/resolv.conf.$$" &&
    mv "$state/resolv.conf.$$" "$state/resolv.conf"; }; then
    die "cannot write $state/resolv.conf"
  fi
  args+=(--ro-bind "$state/resolv.conf" "$(readlink -f /etc/resolv.conf)")
fi

# Per-repository config, .jail (docs/jail.md). Jailed code can write it,
# so only the copy you approved on a terminal is applied; it is read as
# data like .git/config and stored where the jail cannot see it.
ports=() portspec=
esc() { printf '%s' "$1" | cat -vT; } # control characters (also tab) and high bytes as text
# $1 is $2 or below it
within() { [ "$1" = "$2" ] || [ "$2" = / ] || [[ $1 == "$2"/* ]]; }
# A path for ro/rw, or why not: absolute (~/ is your home), no symlink
# on the way, none of what the jail must not get.
bind_path() {
  local p=$1 real x
  # shellcheck disable=SC2088 # a literal ~ from the file
  case $p in "~") p=$HOME ;; "~/"*) p=$HOME/${p#"~/"} ;; esac
  [[ $p == /* ]] || { echo "not an absolute path or ~/..."; return 1; }
  while [[ $p == */ && $p != / ]]; do p=${p%/}; done
  real=$(realpath -e -- "$p" 2>/dev/null) || { echo "does not exist"; return 1; }
  [ "$real" = "$p" ] || { echo "goes through a symlink or is not canonical (it is $(esc "$real"))"; return 1; }
  [ -d "$p" ] || [ -f "$p" ] || { echo "is not a directory or regular file"; return 1; }
  # /.snapshots and /persist hold copies of the home and the host state
  for x in /nix /run /proc /dev /etc /sys /.snapshots /persist; do
    ! within "$p" "$x" || { echo "is in $x"; return 1; }
  done
  [ "$p" != /tmp ] || { echo "is /tmp"; return 1; }
  for x in "$HOME" "$HOME/.local/share/jails" "$HOME/.cache/jails" "$root"; do
    ! within "$x" "$p" || { echo "is or contains $x"; return 1; }
  done
  ! within "$p" "$HOME/.local/share/jails" || { echo "is in the jails' state"; return 1; }
  ! within "$p" "$HOME/.cache/jails" || { echo "is in the jails' caches"; return 1; }
  ! within "$p" "$root" || { echo "is in the repository"; return 1; }
  # keys, logins, transcripts; with rw also what your host session runs or loads
  local sensitive=(.ssh .gnupg .claude .codex .claude.json .local/share/keyrings .password-store) ro_only=()
  [ "$2" = ro ] || ro_only=(.config .local/state .local/bin brain)
  for x in "${sensitive[@]}" "${ro_only[@]}"; do
    if within "$p" "$HOME/$x" || within "$HOME/$x" "$p"; then
      echo "overlaps $HOME/$x$([[ " ${ro_only[*]} " != *" $x "* ]] || echo " (ro only)")"
      return 1
    fi
  done
  printf '%s\n' "$p"
}
# Applies a config's lines to args, mounts and ports; on the first bad
# line says which and why (stderr) and fails.
parse() {
  local n=0 line key val p
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1)) p=""
    [[ ! $line =~ ^[[:space:]]*(#|$) ]] || continue
    read -r key val <<<"$line" || true
    if [[ $val == *[[:cntrl:]]* ]]; then
      p="control characters"
    else
      case $key in
        port)
          if [[ $val =~ ^[1-9][0-9]{3,4}$ ]] && [ "$val" -le 65535 ]; then
            # pasta refuses a port given twice
            [[ " ${ports[*]} " == *" $val "* ]] || ports+=("$val")
          else
            p="a port is a number from 1024 to 65535"
          fi ;;
        ro | rw)
          if p=$(bind_path "$val" "$key"); then
            fdbinds+=("$key" "$p")
            # a link the jail plants in its home at the mount point goes (prepare)
            [[ $p != "$HOME"/* ]] || mounts+=("$p")
            p=
          fi ;;
        # features: I4 adds winvm here
        *) p="unknown keyword (port, ro, rw)" ;;
      esac
    fi
    [ -z "$p" ] || { echo "jail: .jail line $n: $(esc "$line"): $p" >&2; return 1; }
  done <<<"$1"
}
# ports, then the ro and rw paths parse added after fdbinds' first $1 entries
in_effect() {
  local i ro="" rw=""
  for ((i = $1; i < ${#fdbinds[@]}; i += 2)); do
    if [ "${fdbinds[i]}" = ro ]; then ro+=" $(esc "${fdbinds[i + 1]}")"; else rw+=" $(esc "${fdbinds[i + 1]}")"; fi
  done
  echo "ports ${ports[*]:-none} | ro${ro:- none} | rw${rw:- none}"
}
# The config to apply: the approved copy, or the repository's .jail once
# you approve it now. Args: shared or one-off (a taken port then is skipped).
load_config() {
  local approved=$state/jail.approved f=/proc/self/fd/4/.jail conf="" new why="" answer p summary fwd=()
  [ ! -e "$approved" ] || conf=$(cat "$approved") || die "cannot read $approved"
  exec 4<"$root" && [ "$(readlink /proc/self/fd/4)" = "$root" ] || die "$root is not a plain directory"
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    conf= # no .jail: nothing applied
  elif [ -L "$f" ] || [ ! -f "$f" ]; then
    why="it is not a regular file"
  elif [ "$(stat -c %s "$f")" -gt 65536 ]; then
    why="it is larger than 64 KiB"
  elif ! new=$(dd if="$f" iflag=nofollow,nonblock bs=65536 count=1 status=none); then
    why="it cannot be read"
  elif [ "$new" != "$conf" ]; then
    # what the file amounts to, shown below the diff
    if ! summary=$(
      base=${#fdbinds[@]}
      parse "$new" && in_effect "$base"
    ); then
      why="see the line above"
    elif [ ! -t 0 ] || [ ! -t 2 ]; then
      why="it changed, and there is no terminal to approve it"
    else
      if [ -n "$conf" ]; then
        echo "jail: $root/.jail changed since you approved it:"
        { diff -u --label approved --label .jail <(printf '%s\n' "$conf") <(printf '%s\n' "$new") || true; } | cat -vT
      else
        echo "jail: $root/.jail asks for:"
        printf '%s\n' "$new" | cat -vT
      fi >&2
      echo "jail: in effect: $summary" >&2
      printf 'Type yes to apply it (a running shared jail keeps its config until it restarts): ' >&2
      read -r answer || true
      if [ "$answer" = yes ]; then
        { printf '%s\n' "$new" >"$approved.new" && mv "$approved.new" "$approved"; } || die "cannot store $approved"
        conf=$new
      else
        why="not approved"
      fi
    fi
  fi
  exec 4<&-
  if [ -n "$why" ]; then
    printf 'jail: %s/.jail is not applied (%s); %s. To review it, start jail on a terminal.\n' "$root" "$why" \
      "$([ -n "$conf" ] && echo "using the copy you approved last" || echo "nothing approved yet")" >&2
  fi
  parse "$conf" || die "the approved .jail ($approved) no longer applies: change .jail and start jail on a terminal"
  # host 127.0.0.1:PORT, forwarded by jail-run's pasta
  for p in "${ports[@]}"; do
    why=$(ss -Htln "sport = :$p") || die "cannot check port $p (ss)"
    if [ -z "$why" ]; then
      fwd+=("$p")
    elif [ "$1" = shared ]; then
      die "port $p: 127.0.0.1:$p is in use on the host; free it and start the jail again"
    else
      echo "jail: port $p: 127.0.0.1:$p is in use on the host (by this repository's shared jail?), not forwarded" >&2
    fi
  done
  portspec=$(IFS=,; echo "${fwd[*]}")
}

# The environment is built, not inherited: no agent sockets or tokens.
# Only plain settings pass through.
env=(
  --setenv HOME "$HOME" --setenv USER "$user" --setenv LOGNAME "$user"
  --setenv PATH "/etc/profiles/per-user/$user/bin:/run/current-system/sw/bin"
  --setenv SHELL "${SHELL:-/bin/sh}" --setenv LANG "${LANG:-C.UTF-8}"
  --setenv XDG_RUNTIME_DIR "$run"
  --setenv JAIL "$name" # codex takes its jail profile (claude-code/codex/wrapper.nix)
  # no gpg-agent inside, and you do not commit there: commits and tags unsigned
  --setenv GIT_CONFIG_COUNT 2
  --setenv GIT_CONFIG_KEY_0 commit.gpgSign --setenv GIT_CONFIG_VALUE_0 false
  --setenv GIT_CONFIG_KEY_1 tag.gpgSign --setenv GIT_CONFIG_VALUE_1 false
)
for v in TERM COLORTERM EDITOR LOCALE_ARCHIVE TERMINFO_DIRS TZDIR; do
  [ -z "${!v:-}" ] || env+=(--setenv "$v" "${!v}")
done

# The session bus only through jail-run's proxy, its socket outside the
# jail's reach: one per shared jail, one per one-off jail (by PID).
install -d -m 0700 "$run/jails"
bus=
bind_bus() {
  [ -S "$run/bus" ] || return 0
  bus=$1
  args+=(--bind "$bus" "$run/bus")
  env+=(--setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$run/bus")
}

if [ $# -gt 0 ]; then
  load_config one-off
  prepare
  bind_bus "$run/jails/$name.bus-$$"
  # home-manager's session variables, which the shared jail's login shell
  # sources itself; the guard goes, so a shell CMD starts (its /etc/zshenv
  # rebuilds PATH) sources them again
  # shellcheck disable=SC2016 # expanded by the inner shell
  session='. "$0" && unset __HM_SESS_VARS_SOURCED && exec "$@"'
  exec @jailRun@/bin/jail-run "$bus" "$portspec" "${fdbinds[@]}" -- "${args[@]}" "${env[@]}" -- \
    @runtimeShell@ -c "$session" "$vars" "$@"
fi

# Shared jail: one tmux server inside per repository, every terminal attaches.
[ -t 0 ] || die "no terminal; use: jail DIR -- CMD..."
sockdir=$run/jails/$name
sock=$sockdir/tmux.sock
install -d -m 0700 "$sockdir"

# Every tmux client runs sandboxed too: the server is jailed code (or a
# fake one in the writable socket directory) and can make any client
# exec a command (MSG_SHELL, detach-client -E). No --new-session, so
# resizing works; TIOCSTI would need it unless the kernel disables it.
tiocsti=()
[ "$(cat /proc/sys/dev/tty/legacy_tiocsti 2>/dev/null)" = 0 ] || tiocsti=(--new-session)
client_env=()
for v in TERM COLORTERM LANG LOCALE_ARCHIVE TERMINFO_DIRS; do
  [ -z "${!v:-}" ] || client_env+=(--setenv "$v" "${!v}")
done
client() {
  bwrap --unshare-all --die-with-parent "${tiocsti[@]}" --clearenv \
    --ro-bind /nix /nix --ro-bind /etc /etc \
    --ro-bind-try /run/current-system /run/current-system \
    --proc /proc --dev /dev --tmpfs /tmp --bind "$sockdir" "$sockdir" \
    "${client_env[@]}" -- @tmux@/bin/tmux -S "$sock" "$@"
}
alive() { client has-session -t main 2>/dev/null; }

if ! alive; then
  load_config shared
  prepare
  bind_bus "$run/jails/$name.bus"
  # The jail's main process keeps the namespace alive while the session lives.
  # shellcheck disable=SC2016 # expanded by the inner shell
  keepalive='"$1" -S "$2" new-session -d -s main && while "$1" -S "$2" has-session -t main 2>/dev/null; do @coreutils@/bin/sleep 2; done'
  systemd-run --user --quiet --collect --expand-environment=no --unit="jail-$name" -- \
    @jailRun@/bin/jail-run "$bus" "$portspec" "${fdbinds[@]}" -- "${args[@]}" --bind "$sockdir" "$sockdir" "${env[@]}" -- \
    @runtimeShell@ -c "$keepalive" sh @tmux@/bin/tmux "$sock" ||
    echo "jail: jail-$name did not start, maybe it is starting already" >&2
  for _ in $(seq 50); do alive && break; sleep 0.2; done
  alive || die "jail-$name is not running: journalctl --user -u jail-$name; systemctl --user stop jail-$name before the next start"
fi
# attach-session, never new-session -A: that would start a server outside the jail
client attach-session -t main
