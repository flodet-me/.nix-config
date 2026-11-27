# shellcheck shell=bash
# Tests for nix-config-checkout, run while building it (scripts/default.nix).
# usage: test.sh <path to nix-config-checkout>; local file:// repos only.
set -euo pipefail
checkout="$1"
work=$(mktemp -d)
export HOME="$work/home" GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir "$HOME"
git config --global user.name test
git config --global user.email test@example.invalid
git config --global init.defaultBranch main

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The "GitHub" repo: newer than the installer's copy
git init --quiet "$work/origin"
echo new >"$work/origin/flake.nix"
git -C "$work/origin" add flake.nix
git -C "$work/origin" commit --quiet -m init
url="file://$work/origin"
push=git@example.invalid:repo.git

# What install-host leaves: a plain copy plus .install-keep
installer_copy() {
  mkdir -p "$1/keys/hosts"
  echo old >"$1/flake.nix"
  echo key >"$1/keys/hosts/h.age"
  echo stale >"$1/stale"
  printf '%s\n' keys/hosts/h.age >"$1/.install-keep"
}

# The hook records where it ran; it must run only after a swap
# shellcheck disable=SC2016 # $0 expands in the hook
run() { "$checkout" "$@" sh -c 'pwd >"$0"' "$work/hook"; }

expect_checkout() {
  local t="$1"
  [[ -e $t/.git ]] || fail "$t is no checkout"
  [[ $(cat "$t/flake.nix") == new ]] || fail "$t: flake.nix is not origin's"
  [[ $(cat "$t/keys/hosts/h.age") == key ]] || fail "$t: kept file lost"
  [[ ! -e $t/stale ]] || fail "$t: file not in .install-keep carried over"
  [[ $(git -C "$t" status --porcelain) == "?? keys/" ]] || fail "$t: unexpected status"
  [[ $(git -C "$t" remote get-url --push origin) == "$push" ]] || fail "$t: push url"
  [[ $(cat "$work/hook") == "$t" ]] || fail "$t: hook did not run in the checkout"
  [[ ! -e $t-checkout ]] || fail "$t: temp dir left behind"
  rm "$work/hook"
}

# Fresh: the installer's copy becomes a checkout
t="$HOME/fresh"
installer_copy "$t"
run "$t" "$url" "$push"
expect_checkout "$t"

# Existing clean or dirty checkout: never touched, no hook
for kind in clean dirty; do
  t="$HOME/$kind"
  git clone --quiet "$url" "$t"
  if [[ $kind == dirty ]]; then
    echo local >"$t/flake.nix"
    echo mine >"$t/untracked"
  fi
  before=$(git -C "$t" rev-parse HEAD; git -C "$t" status --porcelain; cat "$t/flake.nix")
  run "$t" "$url" "$push"
  after=$(git -C "$t" rev-parse HEAD; git -C "$t" status --porcelain; cat "$t/flake.nix")
  [[ $before == "$after" ]] || fail "$kind checkout was changed"
  [[ ! -e $work/hook ]] || fail "$kind checkout: hook ran"
done

# Interrupted clone (killed, no cleanup ran): the next run still works
t="$HOME/interrupted"
installer_copy "$t"
mkdir -p "$t-checkout/clone"
git init --quiet "$t-checkout/clone"
echo partial >"$t-checkout/clone/half"
run "$t" "$url" "$push"
expect_checkout "$t"

# Clone fails (no network): names the step, changes nothing, retryable
t="$HOME/offline"
installer_copy "$t"
cp -a "$t" "$work/offline.before"
if run "$t" "file://$work/missing" "$push" 2>"$work/err"; then
  fail "a failed clone exited 0"
fi
grep -q clone "$work/err" || fail "failed step not reported: $(cat "$work/err")"
diff -r "$work/offline.before" "$t" || fail "failed clone changed the copy"
[[ ! -e $t-checkout ]] || fail "failed clone left its temp dir"
[[ ! -e $work/hook ]] || fail "failed clone: hook ran"
run "$t" "$url" "$push"
expect_checkout "$t"

echo "nix-config-checkout: all tests passed"
