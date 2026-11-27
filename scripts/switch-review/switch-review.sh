# shellcheck shell=bash
# Review before switch (docs/agent-isolation.md): builds this host's system,
# then diffs the source it was built from ($out/flake-source) against the one
# the running system was built from (/run/current-system/flake-source).
# Full diff of every change except docs/ (names only). It never switches unless
# given --switch, which hands exactly the reviewed build to `nh os switch --ask`.
# It runs no git on the repository: a jail could have written its .git/config
# (pager, external diff, textconv, fsmonitor) to forge the output. nix and nh
# are pinned: inside ~/.nix-config direnv puts the repository's own nix first.
#
# usage: switch-review [--switch] [HOST]   (HOST: this machine, the default)
#        switch-review --dirs OLD NEW      (only compare two source trees)

nix=/run/current-system/sw/bin/nix
nh=@nh@/bin/nh

phase="starting"
step() { phase="$1"; }
on_exit() {
  local rc=$?
  ((rc == 0)) || echo "switch-review FAILED (exit $rc) during: $phase; nothing was switched" >&2
}
trap on_exit EXIT

# Runs a command for which exit 1 is a result (diff: differences).
run1() { "$@" || [[ $? -eq 1 ]]; }

# A file name on one line: backslash and newline escaped; cat -v does the rest.
name() {
  local s=${1//\\/\\\\}
  printf '%s' "${s//$'\n'/\\n}"
}

# What a path is, for the type-change list.
kind() {
  if [[ -L $1 ]]; then
    printf 'symlink to %s' "$(name "$(readlink "$1")")"
  elif [[ -f $1 ]]; then
    echo "regular file"
  elif [[ -d $1 ]]; then
    echo directory
  elif [[ -e $1 ]]; then
    echo "special file ($(stat -c %F "$1"))"
  else
    echo none
  fi
}

review() {
  local old=${1%/} new=${2%/} rel o n ko kn
  local -a files=() changed=() odd=()
  step "comparing $old with $new"
  [[ -d $old && -d $new ]] || {
    echo "switch-review: $old or $new is not a directory" >&2
    exit 1
  }
  mapfile -d '' files < <(find "$old" "$new" -mindepth 1 -printf '%P\0' | sort -zu)
  # find's own errors would vanish in the process substitution; recheck.
  find "$old" "$new" -mindepth 1 >/dev/null
  for rel in "${files[@]}"; do
    o=$old/$rel n=$new/$rel
    if [[ -f $o && ! -L $o && -f $n && ! -L $n ]]; then
      cmp -s "$o" "$n" || changed+=("M" "$rel")
    elif [[ -d $o && ! -L $o && -d $n && ! -L $n ]]; then
      continue
    elif [[ -f $n && ! -L $n && ! -e $o && ! -L $o ]]; then
      changed+=("A" "$rel")
    elif [[ -f $o && ! -L $o && ! -e $n && ! -L $n ]]; then
      changed+=("D" "$rel")
    elif [[ -d $n && ! -L $n && ! -e $o && ! -L $o ]] || [[ -d $o && ! -L $o && ! -e $n && ! -L $n ]]; then
      continue # its files are listed on their own
    else
      ko=$(kind "$o") kn=$(kind "$n")
      [[ $ko == "$kn" && $ko != special* ]] && continue
      odd+=("$(name "$rel"): $ko -> $kn")
      # content of a regular file on either side is shown below
      [[ -f $o && ! -L $o ]] || [[ -f $n && ! -L $n ]] && changed+=("T" "$rel")
    fi
  done

  if ((${#changed[@]} == 0 && ${#odd[@]} == 0)); then
    echo "No changes since the running system was built."
    return
  fi
  echo "== Changed files (A added, D deleted, M modified, T type changed; docs/ without diff) =="
  for ((i = 0; i < ${#changed[@]}; i += 2)); do
    echo "${changed[i]} $(name "${changed[i + 1]}")"
  done
  if ((${#odd[@]})); then
    echo
    echo "== !! Symlinks, special files, type changes: check these !! =="
    printf '!! %s\n' "${odd[@]}"
  fi
  echo
  echo "== Full diff (all but docs/) =="
  for ((i = 0; i < ${#changed[@]}; i += 2)); do
    rel=${changed[i + 1]}
    [[ $rel == docs/* ]] && continue
    o=$old/$rel n=$new/$rel
    [[ -f $o && ! -L $o ]] || o=/dev/null
    [[ -f $n && ! -L $n ]] || n=/dev/null
    run1 diff -a -u --label "a/$(name "$rel")" --label "b/$(name "$rel")" "$o" "$n"
  done
}

# Everything printed (errors too) passes cat -v: CR, ESC, ... made visible.
filtered() {
  "$@" > >(cat -v) 2>&1
  wait $!
}

if [[ ${1:-} == --dirs ]]; then
  [[ $# -eq 3 ]] || {
    echo "usage: switch-review --dirs OLD NEW" >&2
    exit 1
  }
  filtered review "$2" "$3"
  exit 0
fi
switch=no
if [[ ${1:-} == --switch ]]; then
  switch=yes
  shift
fi
[[ $# -le 1 && ${1:-} != -* ]] || {
  echo "usage: switch-review [--switch] [HOST] | switch-review --dirs OLD NEW" >&2
  exit 1
}

this=$(</proc/sys/kernel/hostname)
host=${1:-$this}
if [[ $host != "$this" ]]; then
  echo "switch-review compares this machine's running system (/run/current-system);" >&2
  echo "$host is not this machine ($this); a --target-host deploy is not covered." >&2
  exit 1
fi
flake=${NH_OS_FLAKE:-${NH_FLAKE:-}}
flake=${flake%%#*}
[[ -n $flake ]] || {
  echo "switch-review: neither NH_OS_FLAKE nor NH_FLAKE is set (programs.nh.flake)" >&2
  exit 1
}

step "building $host from $flake"
out=$("$nix" build --no-link --print-out-paths "$flake#nixosConfigurations.\"$host\".config.system.build.toplevel")
[[ -e $out/flake-source ]] || {
  echo "switch-review: the new system $out has no flake-source (not a workstation?)" >&2
  exit 1
}

step "reading the revisions"
current=/run/current-system
# Informational only; a system built from a tree without git has no revision.
old_rev=$("$current/sw/bin/nixos-version" --configuration-revision 2>/dev/null) || old_rev=unknown
# Read, not run: nothing from the new build executes before you agree.
new_rev=$(<"$out/flake-revision")

report() {
  echo "== Revisions ($host) =="
  echo "running: $old_rev  $current -> $(readlink -f "$current")"
  echo "new:     ${new_rev:-unknown}  $out"
  echo
  if [[ ! -e $current/flake-source ]]; then
    echo "The running system has no flake-source (built before switch-review"
    echo "existed), so there is nothing to compare. This switch records it."
  else
    review "$(readlink -f "$current/flake-source")" "$out/flake-source"
  fi
}
filtered report

[[ $switch == yes ]] || exit 0
echo
echo "== Switch: the reviewed build $out =="
step "nh os switch --ask $out"
exec "$nh" os switch --ask "$out"
