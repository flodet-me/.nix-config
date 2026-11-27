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
# A target that already has .git is never touched. Every failure leaves the
# copy as it was, and the next run starts over.

[[ $# -ge 3 ]] || {
  echo "usage: nix-config-checkout <target> <url> <push-url> [hook...]" >&2
  exit 1
}
target="$1"
url="$2"
push="$3"
shift 3

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
step() {
  phase="$1"
  echo "==> $1"
}
# Fixed name next to the target: a run that was killed leaves it behind and
# the next run removes it
tmp="$target-checkout"
cleanup() {
  local rc=$?
  rm -rf "$tmp"
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
step "prepare $tmp"
rm -rf "$tmp"
mkdir "$tmp"

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
