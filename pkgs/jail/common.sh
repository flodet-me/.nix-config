die() { echo "${0##*/}: $*" >&2; exit 1; }

# A file as data: a regular file, never through a link, no wait on a
# FIFO, at most 64 KiB.
read_data() { [ -f "$1" ] && [ ! -L "$1" ] && dd if="$1" iflag=nofollow,nonblock bs=65536 count=1 status=none; }
# one path component: not . or .., no / or control characters
component() { [ -n "$1" ] && [ "$1" != . ] && [ "$1" != .. ] && [[ $1 != */* && $1 != *[[:cntrl:]]* ]]; }

# A git directory as fd 3, checked to be that directory: a link swapped
# in later cannot redirect the reads below. Opened as DIR/. so that a
# FIFO fails at once instead of blocking.
open_gitdir() {
  exec 3<"$1/." && [ "$(readlink /proc/self/fd/3)" = "$1" ] ||
    { echo "${0##*/}: $1 is not a plain directory" >&2; return 1; }
  opened=$1
}
# a file in it as data
read_git_file() { read_data "/proc/self/fd/3/$1" || { echo "${0##*/}: $opened/$1 is not a regular file" >&2; return 1; }; }

# Sets root, the nearest directory above DIR with a real .git directory
# or a container .git file (gitdir: ./NAME, a bare repository NAME in
# it), and gitdir, its git directory. A worktree's or submodule's .git
# file points elsewhere, so they resolve to the repository around them.
# In a container also wt, the worktree DIR is in (empty if none). Plain
# reads only: the jail writes these files.
resolve() {
  local d c name
  d=$(cd "$1" 2>/dev/null && pwd -P) || die "no such directory: $1"
  wt=""
  while :; do
    if [ -d "$d/.git" ] && [ ! -L "$d/.git" ]; then
      root=$d gitdir=$d/.git wt=""
      return
    fi
    if c=$(read_data "$d/.git") && [[ $c == "gitdir: "* ]]; then
      name=${c#gitdir: }
      name=${name#./}
      if [[ $name != */* ]]; then
        component "$name" || die "$d/.git: its gitdir is not one directory name in $d"
        # through fd 3, closed again: bwrap would pass it on to the jail
        { open_gitdir "$d/$name" && c=/proc/self/fd/3 && [ -f "$c/HEAD" ] && [ ! -L "$c/HEAD" ] &&
          [ -d "$c/objects" ] && [ ! -L "$c/objects" ] && [ -d "$c/refs" ] && [ ! -L "$c/refs" ]; } ||
          die "$d/.git: $d/$name is not a bare repository directory (HEAD, objects, refs, no links)"
        exec 3<&-
        root=$d gitdir=$d/$name
        return
      fi
    fi
    # the nearest .git below the root is the worktree's
    [ -n "$wt" ] || { [ ! -e "$d/.git" ] && [ ! -L "$d/.git" ]; } || wt=$d
    [ "$d" != / ] || die "not inside a git repository: $1"
    d=$(dirname "$d")
  done
}
# The worktree's git directory: $wt/.git must name exactly
# $gitdir/worktrees/N, absolute or relative (worktree.useRelativePaths),
# normalized without following links.
worktree_gitdir() {
  local c p
  c=$(read_data "$wt/.git") && [[ $c == "gitdir: "* && $c != *[[:cntrl:]]* ]] || return 1
  p=${c#gitdir: }
  [[ $p == /* ]] || p=$wt/$p
  p=$(realpath -sm -- "$p") && component "${p##*/}" && [ "$p" = "$gitdir/worktrees/${p##*/}" ] && printf '%s\n' "$p"
}
# remote.origin.url; includes would make host git read any path the jail names
origin_url() {
  local cfg
  cfg=$(read_git_file config) && printf '%s\n' "$cfg" | git config --no-includes --file - --get remote.origin.url
}
# Accepted push URLs: ssh, https, scp-like, or an existing bare repository.
valid_url() {
  [[ $1 != *[[:cntrl:]]* ]] || return 1
  local host='[A-Za-z0-9][A-Za-z0-9.-]*' user='[A-Za-z0-9_][A-Za-z0-9._~-]*'
  local ssh="^ssh://($user@)?$host(:[0-9]+)?/[^[:space:]]*$"
  local https="^https://$host(:[0-9]+)?/[^[:space:]]*$"
  local scp="^$user@$host:[A-Za-z0-9._~/][^[:space:]]*$"
  [[ $1 =~ $ssh || $1 =~ $https || $1 =~ $scp ]] && return 0
  [[ $1 = /* && $1 != *[[:space:]]* ]] && [ -f "$1/HEAD" ] && [ -d "$1/objects" ] && [ -d "$1/refs" ]
}
bad_url="use ssh://, https://, user@host:path or the absolute path of a bare repository"
# the mirror outside the jail that jail-push pushes from, with its URL
store_url() {
  { [ -d "$1" ] || git init -q --bare "$1"; } && git --git-dir="$1" config remote.origin.url "$2"
}

# basename plus a short hash of the path: ~/.local/share/jails/<name>
jail_name() {
  local base=${1##*/}
  printf '%s-%s\n' "${base//[^A-Za-z0-9._-]/_}" "$(printf %s "$1" | sha256sum | cut -c1-8)"
}
