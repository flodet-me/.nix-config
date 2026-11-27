[ -z "${JAIL:-}" ] || die "on the host only, not inside a jail (this is jail $JAIL)"
for v in "${!GIT_@}"; do unset "$v"; done # GIT_DIR and friends would redirect git
[ $# -gt 0 ] && [ -d "$1" ] || die "usage: jail-push DIR [git push arguments] (DIR: an existing directory in the repository)"
resolve "$1"
shift
state=$HOME/.local/share/jails/$(jail_name "$root")
mirror=$state/mirror.git
cd /
g() { git --git-dir="$mirror" "$@"; }


open_gitdir "$gitdir" || exit 1
head=$(read_git_file HEAD | head -n 1) || die "cannot read $gitdir/HEAD"
url=$( [ -d "$mirror" ] && g config --get remote.origin.url || true)
if [ -z "$url" ]; then
  # Not recorded when the jail first started: jailed code may have set it.
  url=$(origin_url) || die "$root has no readable remote.origin.url"
  printf -v qurl %q "$url"
  valid_url "$url" || die "refusing remote.origin.url $qurl: $bad_url"
  [ -t 0 ] || die "no push URL stored for $root; run jail-push on a terminal to confirm $qurl"
  printf 'jail-push: no push URL stored for %s; jailed code may have set this one:\n  %s\nType yes to push there from now on: ' "$root" "$qurl" >&2
  read -r answer || true
  [ "$answer" = yes ] || die "not confirmed"
  { mkdir -p "$state" && store_url "$mirror" "$url"; } || die "cannot store the push URL in $mirror"
  echo "jail-push: $root pushes to $qurl from now on (stored in $mirror/config)"
fi

g fetch --quiet --no-tags --prune --upload-pack="@gitSandbox@/bin/jail-git-sandbox git-upload-pack" \
  "$gitdir" '+refs/heads/*:refs/heads/*' || die "fetching $root into $mirror failed"

if [ $# -eq 0 ]; then
  at=$root hd=$gitdir
  if [ -n "$wt" ]; then
    # in a container's worktree: the branch checked out there
    at=$wt
    { hd=$(worktree_gitdir) && open_gitdir "$hd" && head=$(read_git_file HEAD | head -n 1); } ||
      die "$wt/.git does not name a worktree in $gitdir/worktrees: name the branch, e.g. jail-push $wt main"
  fi
  case $head in
    "ref: refs/heads/"?*) branch=${head#ref: refs/heads/} ;;
    *) die "$at has a detached HEAD: name the branch, e.g. jail-push $at main" ;;
  esac
  g check-ref-format --branch "$branch" >/dev/null || die "bad branch name in $hd/HEAD: $branch"
  set -- "refs/heads/$branch"
fi
rp=()
case $url in /*) rp=(--receive-pack="@gitSandbox@/bin/jail-git-sandbox git-receive-pack") ;; esac
g push "${rp[@]}" origin "$@" || die "push to $url failed"
