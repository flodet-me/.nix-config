readme=/run/current-system/sw/share/doc/jail/README.md
usage="usage: jail [DIR] [-- CMD...] | jail COMMAND
Work in a jail:
  jail [DIR]                     a shell in DIR's repository jail (tmux; every terminal attaches to it)
  jail [DIR] -- CMD...           CMD in a fresh one-off jail, its exit status passed on
  jail push [DIR] [GIT-ARGS...]  push DIR's branch from outside (host only; also: jail-push DIR)
Ports and folders:
  jail config [DIR]              check DIR's .jail; approves nothing
Overview:
  jail list                      every jail: repository, running, .jail, push URL, sizes
  jail status [DIR]              jail config, plus running, unit, tmux clients, state, push URL
Manage:
  jail stop [DIR|NAME]           stop the shared jail (ends every shell in it); --all: every one
  jail reset [DIR|NAME] --approved|--home|--all
                                 delete the approved .jail, the jail home, or all its state; asks
  jail help
The commands are fixed words: a directory named list is jail ./list. NAME is a
name from jail list, unless a directory here has that name.
Guide: $readme"
case $HOME in /home/?*) ;; *) die "HOME must be under /home: $HOME" ;; esac
jails=$HOME/.local/share/jails
dir=$PWD cmd="" flag="" arg="" nohost=""
case ${1-} in config | list | status | stop | reset | push | help) cmd=$1 && shift ;; esac
case ${1-} in -h | --help) echo "$usage"; exit 0 ;; esac
case $cmd in
  list | status | stop | reset | push) [ -z "${JAIL:-}" ] || die "$cmd is on the host only (this is jail $JAIL)" ;;
esac
if [ "$cmd" = push ]; then
  # DIR: the first argument if it is a directory; one that looks like a path must be one
  case ${1-} in
    /* | . | .. | ./* | ../*) [ -d "$1" ] || die "no such directory: $1" ;;
    *)
      # a folder here that is also a branch of this repository's mirror: say which
      if [ $# -gt 0 ] && [ -d "$1" ] && n=$(resolve "$PWD" 2>/dev/null && jail_name "$root") &&
        git --git-dir="$jails/$n/mirror.git" show-ref --verify -q "refs/heads/$1" 2>/dev/null; then
        die "push: $1 is a folder here and a branch: jail push ./$1 (the folder) or jail push . $1 (the branch)"
      fi ;;
  esac
  if [ $# -gt 0 ] && [ -d "$1" ]; then dir=$1 && shift; fi
  exec @jailPush@/bin/jail-push "$dir" "$@"
elif [ -n "$cmd" ]; then
  for a; do
    case $a in
      --approved | --home | --all) [ -z "$flag" ] || die "$usage"; flag=$a ;;
      -*) die "$usage" ;;
      *) [ -z "$arg" ] || die "$usage"; arg=$a ;;
    esac
  done
  case $cmd/$flag in
    list/ | help/) [ $# -eq 0 ] || die "$usage" ;;
    config/ | status/ | stop/) ;;
    stop/--all) [ -z "$arg" ] || die "$usage" ;;
    reset/) die "reset: say what to delete: --approved (the approved .jail), --home (the jail home and its Claude plugin data) or --all (all its state and its cache)" ;;
    reset/*) ;;
    *) die "$usage" ;;
  esac
  [ "$cmd" != help ] || { echo "$usage"; exit 0; }
  dir=${arg:-$PWD}
else
  if [ $# -gt 0 ] && [ "$1" != -- ]; then
    dir=$1
    shift
  fi
  if [ $# -gt 0 ]; then
    [ "$1" = -- ] && [ $# -gt 1 ] || die "$usage"
    shift
  fi
fi

# Per-repository config, .jail (docs/jail.md). Jailed code can write it,
# so only the copy you approved on a terminal is applied; it is read as
# data like .git/config and stored where the jail cannot see it.
ports=() portspec="" containers="" winvm=""
esc() { printf '%s' "${1//$'\n'/^J}" | cat -vT; } # control characters (also tab, newline) and high bytes as text
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
  # jail config inside a jail does not see the host's paths
  if [ -z "$nohost" ]; then
    real=$(realpath -e -- "$p" 2>/dev/null) || { echo "does not exist"; return 1; }
    [ "$real" = "$p" ] || { echo "goes through a symlink or is not canonical (it is $(esc "$real"))"; return 1; }
    [ -d "$p" ] || [ -f "$p" ] || { echo "is not a directory or regular file"; return 1; }
  else
    # without the host's paths: at least no . or .. (the comparisons below are textual)
    real=$(realpath -sm -- "$p") && [ "$real" = "$p" ] || { echo "is not canonical (it is $(esc "$real"))"; return 1; }
  fi
  # /.snapshots and /persist hold copies of the home and the host state
  for x in /nix /run /proc /dev /etc /sys /.snapshots /persist; do
    ! within "$p" "$x" || { echo "is in $x"; return 1; }
  done
  [ "$p" != /tmp ] || { echo "is /tmp"; return 1; }
  for x in "$HOME" "$HOME/.local/share/jails" "$HOME/.cache" "$root"; do
    ! within "$x" "$p" || { echo "is or contains $x"; return 1; }
  done
  ! within "$p" "$HOME/.local/share/jails" || { echo "is in the jails' state"; return 1; }
  # the jail's ~/.cache is its own (~/.cache/jails/<name>): a bind below it would land in there
  ! within "$p" "$HOME/.cache" || { echo "is in $HOME/.cache, the jail has its own"; return 1; }
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
        # podman and docker inside (docs/jail.md, Containers)
        containers) [ -z "$val" ] && containers=1 || p="containers takes no value" ;;
        # the host's Windows base images and their key, read-only (docs/jail.md, Windows VMs)
        winvm) [ -z "$val" ] && winvm=1 || p="winvm takes no value" ;;
        *) p="unknown keyword (port, ro, rw, containers, winvm)" ;;
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
  echo "ports ${ports[*]:-none} | ro${ro:- none} | rw${rw:- none}${containers:+ | containers}${winvm:+ | winvm}"
}
# the repository as fd 4, checked to be that directory
open_root() { exec 4<"$root" && [ "$(readlink /proc/self/fd/4)" = "$root" ] || die "$root is not a plain directory"; }
# The repository's .jail (through fd 4) as data into new. Fails with why
# set when it is refused, with why empty when there is none.
read_jail() {
  local f=/proc/self/fd/4/.jail
  new="" why=""
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    return 1
  elif [ -L "$f" ] || [ ! -f "$f" ]; then
    why="it is not a regular file"
  elif [ "$(stat -c %s "$f")" -gt 65536 ]; then
    why="it is larger than 64 KiB"
  elif new=$(dd if="$f" iflag=nofollow,nonblock bs=65536 count=1 status=none); then
    return 0
  else
    why="it cannot be read"
  fi
  return 1
}
sha() { printf %s "$1" | sha256sum | cut -d" " -f1; }

# The jails' state, for list, status, stop and reset. The jail never sees
# $state, so what is in it was written by jail on the host.
at() { state=$jails/$name cache=$HOME/.cache/jails/$name; }
# stop and reset take a NAME (a folder directly in $jails) unless a
# directory here has that name; anything else is a DIR.
target() {
  if component "$1" && [ ! -d "$1" ] && [ -d "$jails/$1" ] && [ ! -L "$jails/$1" ]; then
    name=$1
  else
    resolve "${1:-$PWD}"
    name=$(jail_name "$root")
  fi
  at
}
# The one-off jails running, a name per line: jail-run processes outside a
# shared jail's unit, by the cache they bind (~/.cache/jails/NAME).
# shortcut: a one-off counts from its exec of jail-run, not while it prepares.
oneoffs() {
  local p c a i
  for p in /proc/[0-9]*; do
    { read -r c <"$p/comm" && [ "$c" = jail-run ] && mapfile -d '' -t a <"$p/cmdline" && read -r c <"$p/cgroup"; } 2>/dev/null || continue
    [[ $c != */jail-*.service ]] || continue
    for ((i = 0; i + 1 < ${#a[@]}; i++)); do
      [ "${a[i]}" != "rw:$HOME/.cache" ] || { printf '%s\n' "${a[i + 1]#"$HOME/.cache/jails/"}"; break; }
    done
  done
}
count() { grep -cxF -- "$1" <<<"$offs" || true; } # of oneoffs' output in offs
active() { systemctl --user is-active --quiet "jail-$name"; }
push_url() { [ ! -d "$state/mirror.git" ] || git --git-dir="$state/mirror.git" config --get remote.origin.url || true; }
size() {
  local s=""
  [ ! -e "$1" ] || s=$(du -sh -- "$1" 2>/dev/null || true)
  s=${s%%[[:space:]]*}
  echo "${s:--}"
}
# the .jail of repository $1 against the approved copy: approved, pending, refused or none
jail_state() {
  local conf="" new why
  [ ! -e "$state/jail.approved" ] || conf=$(cat "$state/jail.approved") || { echo "?"; return 0; }
  exec 4<"$1" || { echo "?"; return 0; }
  if read_jail; then
    if [ "$new" = "$conf" ]; then echo approved; else echo pending; fi
  elif [ -n "$why" ]; then
    echo refused
  else
    echo none
  fi
  exec 4<&-
}

if [ "$cmd" = list ]; then
  offs=$(oneoffs)
  {
    printf 'NAME\tREPOSITORY\tSHARED\tONE-OFF\t.JAIL\tPUSH\tHOME\tCACHE\n'
    for state in "$jails"/* "$jails"/.*; do
      name=${state##*/}
      component "$name" && [ -d "$state" ] && [ ! -L "$state" ] || continue
      at
      repo="?" j=none shared=no
      [ ! -e "$state/jail.approved" ] || j=approved
      # written by every start (jails from before have none)
      if [ -f "$state/repo" ] && r=$(cat "$state/repo") && [ "$(jail_name "$r")" = "$name" ]; then
        repo=$(esc "$r")
        if [ -d "$r" ]; then j=$(jail_state "$r"); else repo+=" (gone)"; fi
      fi
      if active; then shared=yes; fi
      url=$(push_url)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(esc "$name")" "$repo" "$shared" "$(count "$name")" "$j" \
        "$(esc "${url:--}")" "$(size "$state/home")" "$(size "$cache")"
    done
  } | column -t -s "$(printf '\t')"
  exit 0
fi

if [ "$cmd" = stop ]; then
  if [ "$flag" = --all ]; then
    stopped=()
    for state in "$jails"/* "$jails"/.*; do
      name=${state##*/}
      if component "$name" && [ -d "$state" ] && active; then
        systemctl --user stop "jail-$name" || die "cannot stop jail-$name"
        stopped+=("jail-$name")
      fi
    done
    [ ${#stopped[@]} -gt 0 ] || { echo "jail stop: no shared jail runs"; exit 0; }
    echo "jail stop: stopped ${stopped[*]}"
    exit 0
  fi
  target "$arg"
  if active; then
    systemctl --user stop "jail-$name" || die "cannot stop jail-$name"
    echo "jail stop: stopped jail-$name"
  else
    echo "jail stop: jail-$name is not running"
  fi
  offs=$(oneoffs) n=$(count "$name")
  [ "$n" = 0 ] || echo "jail stop: $n one-off jail(s) of $name still run; end them where they run"
  exit 0
fi

if [ "$cmd" = reset ]; then
  target "$arg"
  [ -d "$state" ] && [ ! -L "$state" ] || die "no jail state at $state"
  idle() {
    ! active || die "jail-$name runs; stop it first: jail stop $name"
    offs=$(oneoffs) n=$(count "$name")
    [ "$n" = 0 ] || die "$n one-off jail(s) of $name run; end them first"
  }
  idle
  case $flag in
    --approved) del=("$state/jail.approved") ;;
    --home) del=("$state/home" "$state/claude-plugin-data") ;;
    *) del=("$state" "$cache") ;;
  esac
  there=()
  for p in "${del[@]}"; do [ ! -e "$p" ] && [ ! -L "$p" ] || there+=("$p"); done
  [ ${#there[@]} -gt 0 ] || { echo "jail reset: nothing to delete for $name"; exit 0; }
  echo "jail reset: deletes"
  for p in "${there[@]}"; do echo "  $(esc "$p")"; done
  [ "$flag" != --all ] || echo "jail reset: the next start records the push URL again from the repository, which jailed code may have changed: check the URL it prints"
  [ -t 0 ] && [ -t 2 ] || die "no terminal to confirm on; nothing deleted"
  printf 'Delete them? [y/N] ' >&2
  read -r a || true
  case $a in y | Y | yes) ;; *) die "not confirmed; nothing deleted" ;; esac
  # again, after the answer; a start holds the lock (shared) until its jail runs
  exec 9>>"$state/lock" || die "cannot open $state/lock; nothing deleted"
  flock -xn 9 || die "a jail start of $name is in progress; nothing deleted"
  idle
  # rm needs rwx in read-only folders (Go's module cache) or ones jailed code
  # made unreadable: each fixed before find descends (\;); no links followed
  # What containers wrote as your subuids (ADR 0007) only goes in a user
  # namespace that has them; without a range there are none.
  u=()
  ! @jailUserns@/bin/jail-userns true 2>/dev/null || u=(@jailUserns@/bin/jail-userns)
  "${u[@]}" find "${there[@]}" -type d ! -perm -u=rwx -exec chmod u+rwx {} \; || die "cannot make the folders in $name writable; nothing deleted"
  "${u[@]}" rm -rf -- "${there[@]}" || die "deleting failed part way; run jail reset again"
  echo "jail reset: deleted"
  exit 0
fi

resolve "$dir"
cwd=$(cd "$dir" && pwd -P)
case "$HOME/" in "$root"/*) die "$root contains your home directory" ;; esac
name=$(jail_name "$root")
at

# The shared jail's tmux server (started below), for status and the start.
run=${XDG_RUNTIME_DIR:?jail: XDG_RUNTIME_DIR is not set}
sockdir=$run/jails/$name
sock=$sockdir/tmux.sock
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
    "${client_env[@]}" -- @tmux@/bin/tmux -S "$sock" "$@" 9>&-
}
alive() { client has-session -t main 2>/dev/null; }

# jail config: .jail read and checked as a start does; nothing approved,
# nothing written. Inside a jail (JAIL, set by the start below) what is
# in effect comes from the start's environment. jail status adds the
# jail's state, also writing nothing.
if [ "$cmd" = config ] || [ "$cmd" = status ]; then
  fdbinds=() mounts=() rc=0 inside="" cmp=""
  [ -z "${JAIL:-}" ] || inside=1 nohost=1
  hint="To apply it: on a host terminal, jail stop $(esc "$root") (this ends every shell in that jail), then jail $(esc "$root"); it shows the change and applies it once you type yes."
  echo "jail config: $(esc "$root")/.jail"
  open_root
  if read_jail; then
    if add=$(parse "$new" && in_effect 0); then
      echo "would add: $add"
      cmp=1 # a start would apply it, also an empty one
    else
      echo "jail config: that line is refused; a start would not apply this .jail"
      rc=1
    fi
  elif [ -n "$why" ]; then
    echo "jail config: .jail is not applied: $why"
    rc=1
  else
    echo "would add: nothing (no .jail; the next start applies nothing)"
  fi
  exec 4<&-
  [ -z "$inside" ] || echo "not checked inside a jail (they need the host's paths): whether each ro/rw path exists, is a directory or regular file, and has no symlink in it; the host checks that when you approve"
  if [ -n "$inside" ]; then
    if [ "$JAIL" != "$name" ]; then
      echo "in effect: not known here: this is jail $JAIL, and $root has a jail of its own"
    elif [ -z "${JAIL_IN_EFFECT:-}" ]; then
      echo "in effect: not known (this jail started before jail config: restart it)"
    else
      echo "in effect in this jail: $JAIL_IN_EFFECT"
      if [ -z "$cmp" ]; then :
      elif [ "$(sha "$new")" = "${JAIL_APPLIED_SHA256:-}" ]; then
        echo ".jail matches what is in effect in this jail"
      else
        echo ".jail differs from what is in effect in this jail: pending your approval at the next start"
        echo "$hint"
      fi
    fi
  else
    approved=$state/jail.approved conf=""
    if [ ! -e "$approved" ]; then
      echo "approved: nothing yet"
    else
      conf=$(cat "$approved") || die "cannot read $approved"
      if s=$(parse "$conf" && in_effect 0); then
        echo "approved: $s"
      else
        echo "approved: $approved no longer applies (the line above); the next start stops until .jail changes and you approve it"
      fi
    fi
    if [ -z "$cmp" ]; then :
    elif [ "$new" = "$conf" ]; then
      echo ".jail matches the approved copy (applied at the next start; a running shared jail keeps what it started with)"
    else
      echo ".jail differs from the approved copy: pending your approval"
      echo "$hint"
    fi
  fi
  if [ "$cmd" = status ]; then
    offs=$(oneoffs) n=$(count "$name") running=""
    unit=$(systemctl --user is-active "jail-$name" || true)
    [ "$unit" != active ] || running=shared
    [ "$n" = 0 ] || running+="${running:+, }$n one-off"
    echo "running: ${running:-no}"
    echo "unit: jail-$name ($unit)"
    # a count only: the server is jailed code
    clients=0
    [ "$unit" != active ] || clients=$({ client list-clients 2>/dev/null || true; } | wc -l)
    echo "tmux clients: $clients"
    echo "state: $state$([ -d "$state" ] || echo " (none yet)")"
    echo "cache: $cache$([ -d "$cache" ] || echo " (none yet)")"
    url=$(push_url)
    echo "push: $([ -n "$url" ] && esc "$url" || echo "none recorded (jail push asks on first use)")"
  fi
  exit "$rc"
fi

user=$(id -un)
jhome=$state/home
# Held (shared) until the jail runs, so jail reset does not delete what
# this start prepares; closed before anything jailed gets it (9>&-).
# shortcut: a one-off releases it just before its exec of jail-run, which
# jail reset counts; a reset scanning in that instant misses it.
first=""
[ -e "$state" ] || first=1
{ mkdir -p "$state" && exec 9>>"$state/lock"; } || die "cannot open $state/lock"
flock -sn 9 || die "jail reset of $name runs; start again after it"
if [ -n "$first" ]; then
  # First start: no jailed code has run for this repository yet, so its
  # push URL is still yours. Later ones jail push asks you to confirm.
  if open_gitdir "$gitdir" && url=$(origin_url) && valid_url "$url"; then
    store_url "$state/mirror.git" "$url" || die "cannot store the push URL in $state/mirror.git"
    printf 'jail: jail push %s pushes to %q\n' "$root" "$url"
  else
    echo "jail: no push URL recorded for $root (none, or refused: $bad_url); jail push asks on first use" >&2
  fi
  exec 3<&-
fi
mkdir -p "$jhome"
# the repository, for jail list
{ printf '%s\n' "$root" >"$state/repo.$$" && mv "$state/repo.$$" "$state/repo"; } || die "cannot write $state/repo"
# The jail's ~/.cache, outside the /home snapshots (~/.cache is a subvolume
# of its own). Before, it was in the jail home: that one stays, unused
# (prepare links home-manager's files under .cache in there on every start).
if [ ! -e "$cache" ] && [ -d "$jhome/.cache" ] && [ ! -L "$jhome/.cache" ] &&
  [ -n "$(find "$jhome/.cache" ! -type d ! -lname '/nix/store/*-home-manager-files/*' -print -quit)" ]; then
  echo "jail: the jail's cache is now $cache; the old one, $jhome/.cache, is no longer used (delete it while the jail is stopped)" >&2
fi
mkdir -p "$cache" || die "cannot create $cache"

# On every start: dotfiles, mount points, direnv's whitelist, ~/.claude.json (prepareHome).
prepare() {
  local gen=$HOME/.local/state/home-manager/gcroots/current-home files host=()
  files=$(readlink -f "$gen/home-files") && [ -d "$files" ] ||
    die "no home-manager generation at $gen (home-manager not activated yet?)"
  vars=$(readlink -f "$gen/home-path/etc/profile.d/hm-session-vars.sh") && [ -f "$vars" ] ||
    die "no hm-session-vars.sh in the home-manager generation at $gen"
  [ ! -f "$HOME/.claude.json" ] || host=(--ro-bind "$HOME/.claude.json" /tmp/host.json)
  bwrap --unshare-all --die-with-parent --clearenv --ro-bind /nix /nix \
    --proc /proc --dev /dev --tmpfs /tmp "${host[@]}" --bind "$jhome" /tmp/home \
    -- @prepareHome@/bin/jail-prepare-home "$files" "$root" "${mounts[@]#"$HOME"/}" 9>&- ||
    die "could not prepare $jhome; to start over, reset its home ($readme, Reset)"
}

# Namespaces: jail-run's (all new, the network pasta's). The host's name, not
# pasta's pasta-<host>: /etc/hosts resolves it (no nscd, no myhostname inside),
# so `hostname --fqdn` in /etc/zshrc does not fail.
args=(
  --die-with-parent --new-session --clearenv
  --hostname "$(</proc/sys/kernel/hostname)"
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

# The config to apply: the approved copy, or the repository's .jail once
# you approve it now. Args: shared or one-off (a taken port then is skipped).
load_config() {
  local approved=$state/jail.approved conf="" new why="" answer p summary fwd=() base
  [ ! -e "$approved" ] || conf=$(cat "$approved") || die "cannot read $approved"
  open_root
  if ! read_jail; then
    [ -n "$why" ] || conf= # no .jail: nothing applied
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
  base=${#fdbinds[@]}
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
  # for jail config inside: what this jail got, and from which .jail
  env+=(--setenv JAIL_IN_EFFECT "$(ports=("${fwd[@]}") && in_effect "$base")" --setenv JAIL_APPLIED_SHA256 "$(sha "$conf")")
}

# The environment is built, not inherited: no agent sockets or tokens.
# Only plain settings pass through.
env=(
  --setenv HOME "$HOME" --setenv USER "$user" --setenv LOGNAME "$user"
  --setenv PATH "/etc/profiles/per-user/$user/bin:/run/current-system/sw/bin"
  --setenv SHELL "${SHELL:-/bin/sh}" --setenv LANG "${LANG:-C.UTF-8}"
  --setenv XDG_RUNTIME_DIR "$run"
  --setenv JAIL "$name" # codex takes its jail profile (claude-code/codex/wrapper.nix)
  # winvm's VMs: the jail's own, in its cache (not in the /home snapshots); it
  # wins over ~/.config/winvm/home, which names the host's
  --setenv WINVM_HOME "$HOME/.cache/winvm"
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

# Containers (.jail: containers; ADR 0007): podman, docker and shadow's
# plain newuidmap first in PATH, /var/tmp for image layers (outside the
# jail's reach, like the resolv.conf), and the jail's own API service,
# started by the init in front of the command.
init=()
with_containers() {
  [ -n "$containers" ] || return 0
  # without a subuid range: refused here, on the terminal, not in the unit's journal
  @jailUserns@/bin/jail-userns true || exit 1
  mkdir -p "$state/var-tmp" || die "cannot create $state/var-tmp"
  args+=(--dev-bind-try /dev/net/tun /dev/net/tun --bind "$state/var-tmp" /var/tmp --ro-bind @containersBin@ /run/wrappers/bin)
  env+=(
    --setenv PATH "/run/wrappers/bin:/etc/profiles/per-user/$user/bin:/run/current-system/sw/bin"
    --setenv CONTAINERS_CONF @containersConf@/containers.conf
    --setenv CONTAINERS_STORAGE_CONF @containersConf@/storage.conf
    --setenv CONTAINERS_REGISTRIES_CONF @containersConf@/registries.conf
    --setenv CONTAINERS_POLICY_JSON @containersConf@/policy.json
    --setenv DOCKER_HOST "unix://$run/podman/podman.sock"
    --setenv DOCKER_BUILDKIT 0 # buildx's builder needs a cgroup it can write; podman builds
  )
  init=(@containersInit@/bin/jail-containers-init)
}

# Windows VMs (.jail: winvm; ADR 0007): the host's base images and the key
# they trust, read-only in the jail's WINVM_HOME; its VMs are its own.
with_winvm() {
  [ -n "$winvm" ] || return 0
  local h=${WINVM_HOME:-} f=${XDG_CONFIG_HOME:-$HOME/.config}/winvm/home x p why
  # where winvm on the host finds its home (pkgs/winvm/winvm)
  if [ -z "$h" ] && [ -f "$f" ]; then
    read -r h <"$f" || true # no final newline
    [[ $h == /* ]] || die "winvm: $f: $(esc "$h") is not an absolute path"
  fi
  h=${h:-${XDG_DATA_HOME:-$HOME/.local/share}/winvm}
  for x in images id_ed25519 id_ed25519.pub; do
    p=$(realpath -e -- "$h/state/$x" 2>/dev/null) || continue # not there: nothing to share
    why=$(bind_path "$p" ro) || die "winvm: $(esc "$p"): $why"
    fdbinds+=("ro:$HOME/.cache/winvm/state/$x" "$p")
  done
}

if [ $# -gt 0 ]; then
  load_config one-off
  with_containers
  with_winvm
  prepare
  bind_bus "$run/jails/$name.bus-$$"
  # home-manager's session variables, which the shared jail's login shell
  # sources itself; the guard goes, so a shell CMD starts (its /etc/zshenv
  # rebuilds PATH) sources them again
  # shellcheck disable=SC2016 # expanded by the inner shell
  session='. "$0" && unset __HM_SESS_VARS_SOURCED && exec "$@"'
  exec 9>&-
  # in a scope of its own: the jail's cgroup is not the terminal's (podman
  # and a cgroup2 mount inside see only it)
  exec systemd-run --user --scope --quiet --collect --expand-environment=no --unit="jail-$name-$$" -- @jailRun@/bin/jail-run "$bus" "$portspec" "$containers" "${fdbinds[@]}" -- "${args[@]}" "${env[@]}" -- \
    "${init[@]}" @runtimeShell@ -c "$session" "$vars" "$@"
fi

# Shared jail: one tmux server inside per repository, every terminal attaches.
[ -t 0 ] || die "no terminal; use: jail DIR -- CMD..."
install -d -m 0700 "$sockdir"

if ! alive; then
  load_config shared
  with_containers
  with_winvm
  prepare
  bind_bus "$run/jails/$name.bus"
  # The jail's main process keeps the namespace alive while the session lives.
  # shellcheck disable=SC2016 # expanded by the inner shell
  keepalive='"$1" -S "$2" new-session -d -s main && while "$1" -S "$2" has-session -t main 2>/dev/null; do @coreutils@/bin/sleep 2; done'
  systemd-run --user --quiet --collect --expand-environment=no --unit="jail-$name" -- \
    @jailRun@/bin/jail-run "$bus" "$portspec" "$containers" "${fdbinds[@]}" -- "${args[@]}" --bind "$sockdir" "$sockdir" "${env[@]}" -- \
    "${init[@]}" @runtimeShell@ -c "$keepalive" sh @tmux@/bin/tmux "$sock" 9>&- ||
    echo "jail: jail-$name did not start, maybe it is starting already" >&2
  for _ in $(seq 50); do alive && break; sleep 0.2; done
  alive || die "jail-$name is not running: journalctl --user -u jail-$name; jail stop $(esc "$root") before the next start"
fi
exec 9>&-
# attach-session, never new-session -A: that would start a server outside the jail
client attach-session -t main
