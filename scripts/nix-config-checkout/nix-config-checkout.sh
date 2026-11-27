# shellcheck shell=bash
# install-host leaves a plain copy of the repo (no .git) in ~/.nix-config.
# This replaces it with a checkout of <url> and carries over only what the
# install added (listed in .install-keep: the host's sops key, the disk if
# changed), so a stick older than the repo never overwrites newer files.
# Then <hook> runs inside the new checkout (only after a swap done here).
#
# usage: nix-config-checkout <target> <url> <push-url> [hook...]
# Callers: the user service (home/flodet/_shared/components/nix-config-checkout.nix,
# hook: sops-sync + commit) and the server service
# (hosts/_shared/components/server/nix-config-checkout.nix, no hook).
# A target that already has .git is never touched. A failure (or kill)
# before the swap leaves the copy as it was and the next run starts over;
# after the swap the target is a checkout, the run exits != 0 naming the
# step, and the rest (the hook) is left to do by hand. Only a temp dir holding
# our marker is ever deleted.

[[ $# -ge 3 ]] || {
  echo "usage: nix-config-checkout <target> <url> <push-url> [hook...]" >&2
  exit 1
}
target="${1%/}"
url="$2"
push="$3"
shift 3

# Fixed name next to the target, so the next run finds what a killed one left
tmp="$target-checkout"
marker=.nix-config-checkout
ours() { [[ ! -L $tmp && -d $tmp && -f $tmp/$marker ]]; }
if ours; then
  echo "removing $tmp, left by a killed run"
  rm -rf "$tmp"
fi

if [[ -e $target/.git ]]; then
  echo "$target is a git checkout already, left alone"
  exit 0
fi
if [[ ! -f $target/flake.nix ]]; then
  echo "$target/flake.nix does not exist, nothing to turn into a checkout"
  exit 0
fi

phase="starting"
swapped=false
created=false
step() {
  phase="$1"
  echo "==> $1"
}
cleanup() {
  local rc=$?
  if $created; then rm -rf "$tmp"; fi
  if ((rc != 0)); then
    echo "nix-config-checkout FAILED (exit $rc) during: $phase" >&2
    if $swapped; then
      echo "$target is a checkout already; finish the step by hand." >&2
    else
      echo "$target is unchanged; the next run starts over." >&2
    fi
  fi
}
trap cleanup EXIT
# systemd stops the unit with SIGTERM: report the step like an error
trap 'exit 143' TERM
trap 'exit 130' INT
step "prepare $tmp"
if [[ -e $tmp || -L $tmp ]]; then
  echo "$tmp exists and is not ours (no $marker in it): left alone, move it away" >&2
  exit 1
fi
# Marker first, then one rename: $tmp never exists without it
new=$(mktemp -d "$tmp.XXXXXX")
touch "$new/$marker"
mv --no-target-directory "$new" "$tmp"
created=true

step "clone $url"
git clone --quiet "$url" "$tmp/clone"
git -C "$tmp/clone" remote set-url --push origin "$push"

step "carry over the files in .install-keep"
if [[ -f $target/.install-keep ]]; then
  while IFS= read -r f; do
    if [[ -n $f ]]; then
      install -D -m 644 "$target/$f" "$tmp/clone/$f"
    fi
  done <"$target/.install-keep"
fi

# One atomic rename: there is no moment without a $target
step "swap the checkout in"
mv --exchange --no-target-directory "$tmp/clone" "$target"
swapped=true
echo "$target is a checkout of $url now; added by the install:"
git -C "$target" status --short

if (($# > 0)); then
  step "run $1 in the checkout"
  cd "$target"
  "$@"
fi
