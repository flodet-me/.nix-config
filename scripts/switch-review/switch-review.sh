# shellcheck shell=bash
# Review before switch (docs/agent-isolation.md): what changed between the
# source the running system was built from (/run/current-system/flake-source)
# and the source nix would build now. It only prints; it never switches.
# It runs no git on the repository: a jail could have written its .git/config
# (pager, external diff, textconv, fsmonitor) to forge the output. The new
# source comes from nix's own fetch, as `nh os switch` does it.
#
# usage: switch-review [HOST]          (HOST: this machine, the default)
#        switch-review --dirs OLD NEW  (only compare two source trees)

# Full diff for these paths (relative to the flake root; zsh.nix holds `update`).
security_paths='^(\.claude/|CLAUDE\.md$|AGENTS\.md$|home/[^/]+/_shared/components/(claude-code/|jail/|zsh\.nix$)|hosts/_shared/components/(claude-code|nix|server-access)\.nix$|hosts/_shared/components/server/|hosts/_shared/users/|(.*/)?impermanence/|\.sops\.yaml$|keys/|(.*/)?[^/]*secrets\.yaml$|flake\.(nix|lock)$|overlays/|pkgs/|scripts/)'
# Changed lines elsewhere are shown when they match these (case-insensitive).
keywords='sudo|polkit|groups|trusted.?users|wrappers|setuid|setgid|capabilit|permission|hook'

phase="starting"
step() { phase="$1"; }
on_exit() {
  local rc=$?
  ((rc == 0)) || echo "switch-review FAILED (exit $rc) during: $phase" >&2
}
trap on_exit EXIT

# Runs a command for which exit 1 is a result (diff: differences, grep: no match).
run1() { "$@" || [[ $? -eq 1 ]]; }

review() {
  local old=${1%/} new=${2%/} list line rel
  local -a changed=() other=()
  step "comparing $old with $new"
  [[ -d $old && -d $new ]] || {
    echo "switch-review: $old or $new is not a directory" >&2
    exit 1
  }
  list=$(run1 diff -rqN --no-dereference "$old" "$new")
  if [[ -z $list ]]; then
    echo "No changes since the running system was built."
    return
  fi
  while IFS= read -r line; do
    case $line in
      "Files $old/"*" and $new/"*" differ")
        rel=${line#"Files $old/"}
        changed+=("${rel%%" and $new/"*}")
        ;;
      *) other+=("$line") ;; # type changes (file <-> directory, symlink)
    esac
  done <<<"$list"

  echo "== Changed files (A added, D deleted, M modified; ! full diff below) =="
  for rel in "${changed[@]}"; do
    if [[ ! -e $old/$rel && ! -L $old/$rel ]]; then
      line=A
    elif [[ ! -e $new/$rel && ! -L $new/$rel ]]; then
      line=D
    else
      line=M
    fi
    [[ $rel =~ $security_paths ]] && line+=" !" || line+="  "
    echo "$line $rel"
  done
  for line in "${other[@]}"; do echo "?   $line"; done

  echo
  echo "== Security-relevant paths: full diff =="
  local shown=0
  for rel in "${changed[@]}"; do
    [[ $rel =~ $security_paths ]] || continue
    run1 diff -uN --no-dereference --label "a/$rel" --label "b/$rel" "$old/$rel" "$new/$rel"
    shown=1
  done
  ((shown)) || echo "(none)"

  echo
  echo "== Security keywords ($keywords) in other changed files =="
  local hits found=0
  for rel in "${changed[@]}"; do
    [[ $rel =~ $security_paths ]] && continue
    hits=$(run1 diff -N --no-dereference --unchanged-line-format= --old-line-format='-%L' \
      --new-line-format='+%L' "$old/$rel" "$new/$rel" | run1 grep -iE "$keywords")
    [[ -n $hits ]] || continue
    while IFS= read -r line; do echo "$rel: $line"; done <<<"$hits"
    found=1
  done
  ((found)) || echo "(none)"
}

if [[ ${1:-} == --dirs ]]; then
  [[ $# -eq 3 ]] || {
    echo "usage: switch-review --dirs OLD NEW" >&2
    exit 1
  }
  review "$2" "$3"
  exit 0
fi
[[ $# -le 1 && ${1:-} != -* ]] || {
  echo "usage: switch-review [HOST] | switch-review --dirs OLD NEW" >&2
  exit 1
}

this=$(</proc/sys/kernel/hostname)
host=${1:-$this}
if [[ $host != "$this" ]]; then
  echo "switch-review compares this machine's running system (/run/current-system);" >&2
  echo "$host is not this machine ($this); a --target-host deploy is not covered." >&2
  exit 1
fi

step "reading the running system"
current=/run/current-system
if [[ ! -e $current/flake-source ]]; then
  echo "The running system of $host has no flake-source (built before switch-review"
  echo "existed), so there is nothing to compare. The next switch records it."
  exit 0
fi
old=$(readlink -f "$current/flake-source")
# Informational only; a system built from a tree without git has no revision.
old_rev=$("$current/sw/bin/nixos-version" --configuration-revision 2>/dev/null) || old_rev=unknown

flake=${NH_OS_FLAKE:-${NH_FLAKE:-}}
flake=${flake%%#*}
[[ -n $flake ]] || {
  echo "switch-review: neither NH_OS_FLAKE nor NH_FLAKE is set (programs.nh.flake)" >&2
  exit 1
}
step "fetching the source nix would build from $flake (nix flake prefetch)"
# prefetch, not metadata: with lazy trees only prefetch puts the source in the store.
meta=$(nix flake prefetch --json "$flake")
new=$(jq -er .storePath <<<"$meta")
new_rev=$(jq -r '.locked.rev // .locked.dirtyRev // "unknown"' <<<"$meta")

echo "== Revisions ($host) =="
echo "running: $old_rev  $old"
echo "new:     $new_rev  $new"
echo
review "$old" "$new"
