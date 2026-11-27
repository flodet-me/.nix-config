# shellcheck shell=bash
# Review before switch (docs/agent-isolation.md). It copies the flake's tracked
# tree into the store first (nix flake prefetch), builds exactly that store
# path (path:$src), requires the build's flake-source to be that path, and
# diffs it against the source the running system was built from
# (/run/current-system/flake-source). Full diff of every change except
# docs/**/*.md (names only). It never switches unless given --switch, which
# hands exactly the reviewed build to `nh os switch --ask`.
# It runs no git on the repository: a jail could have written its .git/config
# (pager, external diff, textconv, fsmonitor) to forge the output. nix and nh
# are pinned: inside ~/.nix-config direnv puts the repository's own nix first.
#
# usage: switch-review [--switch] [HOST]   (HOST: this machine, the default)
#        switch-review --dirs OLD NEW      (only compare two source trees)

nix=/run/current-system/sw/bin/nix
nh=@nh@/bin/nh
current=/run/current-system
# The dev shell's (the repository's) nix settings must not steer the build.
unset NIX_CONFIG

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

# What a path is, for the type-change list ("" = not in that tree).
kind() {
  if [[ -L $1 ]]; then
    printf 'symlink to %s' "$(name "$(readlink "$1")")"
  elif [[ -f $1 ]]; then
    echo "regular file"
  elif [[ -d $1 ]]; then
    echo directory
  elif [[ -n $1 && -e $1 ]]; then
    echo "special file ($(stat -c %F "$1"))"
  else
    echo none
  fi
}

# Size and hash of a regular file ("" = none).
fileinfo() {
  if [[ -n $1 ]]; then
    printf '%s bytes sha256 %s' "$(stat -c %s "$1")" "$(sha256sum <"$1" | cut -d' ' -f1)"
  else
    echo none
  fi
}
hasnul() { [[ -n $1 && $(tr -dc '\0' <"$1" | wc -c) -gt 0 ]]; }
size() { if [[ -n $1 ]]; then stat -c %s "$1"; else echo 0; fi; }

# Binary (NUL) files are diffed as text up to 64 KiB (a script can hide code
# behind a NUL), any file up to 1 MiB; beyond that only size and hash. Both
# are always listed loudly.
max_binary=65536 max_text=1048576

# The relative names in a root; find does not follow symlinks, so nothing
# behind a symlinked directory (which may lead out of the root) is listed.
list() { find "$1" -mindepth 1 -printf '%P\0'; }

review() {
  local old new rel o n ko kn note
  local -a files=() changed=() odd=()
  local -A in_old=() in_new=() nodiff=()
  step "comparing $1 with $2"
  # Resolved roots: find lists a symlinked root itself, not what is in it.
  old=$(readlink -f -- "$1") new=$(readlink -f -- "$2")
  [[ -d $old && -d $new ]] || {
    echo "switch-review: $1 or $2 is not a directory" >&2
    exit 1
  }
  while IFS= read -r -d '' rel; do in_old[$rel]=1; done < <(list "$old")
  while IFS= read -r -d '' rel; do in_new[$rel]=1; done < <(list "$new")
  # find's own errors would vanish in the process substitution; recheck.
  list "$old" >/dev/null
  list "$new" >/dev/null
  mapfile -d '' files < <(printf '%s\0' "${!in_old[@]}" "${!in_new[@]}" | sort -zu)
  for rel in "${files[@]}"; do
    [[ -n $rel ]] || continue
    # A path a tree does not list itself is "none" there and is never read.
    o='' n=''
    [[ -n ${in_old[$rel]:-} ]] && o=$old/$rel
    [[ -n ${in_new[$rel]:-} ]] && n=$new/$rel
    if [[ -f $o && ! -L $o && -f $n && ! -L $n ]]; then
      cmp -s "$o" "$n" || changed+=("M" "$rel")
    elif [[ -d $o && ! -L $o && -d $n && ! -L $n ]]; then
      continue
    elif [[ -f $n && ! -L $n && -z $o ]]; then
      changed+=("A" "$rel")
    elif [[ -f $o && ! -L $o && -z $n ]]; then
      changed+=("D" "$rel")
    elif [[ -d $n && ! -L $n && -z $o ]] || [[ -d $o && ! -L $o && -z $n ]]; then
      continue # its files are listed on their own
    else
      ko=$(kind "$o") kn=$(kind "$n")
      [[ $ko == "$kn" && $ko != special* ]] && continue
      odd+=("$(name "$rel"): $ko -> $kn")
      # content of a regular file on either side is shown below
      [[ -f $o && ! -L $o ]] || [[ -f $n && ! -L $n ]] && changed+=("T" "$rel")
    fi
  done
  # Binary and large files: loud, with size and hash.
  for ((i = 0; i < ${#changed[@]}; i += 2)); do
    rel=${changed[i + 1]}
    [[ $rel == docs/*.md ]] && continue
    o='' n=''
    [[ -n ${in_old[$rel]:-} && -f $old/$rel && ! -L $old/$rel ]] && o=$old/$rel
    [[ -n ${in_new[$rel]:-} && -f $new/$rel && ! -L $new/$rel ]] && n=$new/$rel
    note=
    if hasnul "$o" || hasnul "$n"; then
      note=binary
      (($(size "$o") > max_binary || $(size "$n") > max_binary)) && note+=", not diffed" && nodiff[$rel]=1
    elif (($(size "$o") > max_text || $(size "$n") > max_text)); then
      note="too large to diff" && nodiff[$rel]=1
    fi
    [[ -n $note ]] && odd+=("$(name "$rel"): $note, old: $(fileinfo "$o"), new: $(fileinfo "$n")")
  done

  if ((${#changed[@]} == 0 && ${#odd[@]} == 0)); then
    echo "No changes since the running system was built."
    return
  fi
  echo "== Changed files (A added, D deleted, M modified, T type changed; docs/**/*.md without diff) =="
  for ((i = 0; i < ${#changed[@]}; i += 2)); do
    echo "${changed[i]} $(name "${changed[i + 1]}")"
  done
  if ((${#odd[@]})); then
    echo
    echo "== !! Symlinks, special files, type changes, binary and large files: check these !! =="
    printf '!! %s\n' "${odd[@]}"
  fi
  echo
  echo "== Full diff (all but docs/**/*.md) =="
  for ((i = 0; i < ${#changed[@]}; i += 2)); do
    rel=${changed[i + 1]}
    [[ $rel == docs/*.md || -n ${nodiff[$rel]:-} ]] && continue
    o=/dev/null n=/dev/null
    [[ -n ${in_old[$rel]:-} && -f $old/$rel && ! -L $old/$rel ]] && o=$old/$rel
    [[ -n ${in_new[$rel]:-} && -f $new/$rel && ! -L $new/$rel ]] && n=$new/$rel
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

# Prefetch, build, pin check and review; nix's output too (builtins.trace of
# the unreviewed tree) passes cat -v.
prepare() {
  local meta rev ref old_rev
  step "copying $flake into the store (nix flake prefetch)"
  meta=$("$nix" flake prefetch --json "$flake")
  src=$(jq -r '.storePath' <<<"$meta")
  [[ -d $src && ! -L $src && $(readlink -f -- "$src") == "$src" ]] || {
    echo "switch-review: prefetch gave no store directory: $src" >&2
    exit 1
  }
  # A clean tree keeps its revision (the same toplevel as a git+file build);
  # path: takes no dirtyRev, so a dirty tree records its narHash (flake.nix).
  rev=$(jq -r '.locked.rev // empty' <<<"$meta")
  ref=path:$src
  [[ -n $rev ]] && ref+=$(jq -r '"?rev=\(.locked.rev)&revCount=\(.locked.revCount)&lastModified=\(.locked.lastModified)"' <<<"$meta")

  step "building $host from $src"
  out=$("$nix" build --no-link --print-out-paths --no-update-lock-file \
    "$ref#nixosConfigurations.\"$host\".config.system.build.toplevel")
  [[ -e $out/flake-source ]] || {
    echo "switch-review: the new system $out has no flake-source (not a workstation?)" >&2
    exit 1
  }
  step "checking that $out was built from $src"
  [[ $(readlink -f -- "$out/flake-source") == "$src" ]] || {
    echo "switch-review: $out/flake-source is $(readlink -f -- "$out/flake-source"), not the reviewed $src" >&2
    exit 1
  }

  # Informational only; a system built from a tree without git has no revision.
  old_rev=$("$current/sw/bin/nixos-version" --configuration-revision 2>/dev/null) || old_rev=unknown
  echo "== Revisions ($host) =="
  echo "running: $old_rev  $current -> $(readlink -f "$current")"
  echo "new:     $(jq -r '.locked.rev // .locked.dirtyRev // "unknown"' <<<"$meta")  $out"
  echo "source:  $src"
  echo
  if [[ ! -e $current/flake-source ]]; then
    echo "The running system has no flake-source (built before switch-review"
    echo "existed), so there is nothing to compare. This switch records it."
  else
    review "$current/flake-source" "$src"
  fi
}
filtered prepare

[[ $switch == yes ]] || exit 0
echo
echo "== Switch: the reviewed build $out =="
step "nh os switch --ask $out"
# The system's tools, not the dev shell's.
export PATH=/run/wrappers/bin:$current/sw/bin
exec "$nh" os switch --ask "$out"
