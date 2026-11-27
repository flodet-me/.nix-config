# shellcheck shell=bash
# shellcheck disable=SC2016 # the hooks expand their own $0 and $$
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
run() { "$checkout" "$@" sh -c 'pwd >"$0"' "$work/hook"; }

# $2=nohook: called without a hook (the server's form)
expect_checkout() {
  local t="$1" hook="${2:-}"
  [[ -e $t/.git ]] || fail "$t is no checkout"
  [[ $(cat "$t/flake.nix") == new ]] || fail "$t: flake.nix is not origin's"
  [[ $(cat "$t/keys/hosts/h.age") == key ]] || fail "$t: kept file lost"
  [[ ! -e $t/stale ]] || fail "$t: file not in .install-keep carried over"
  [[ $(git -C "$t" status --porcelain) == "?? keys/" ]] || fail "$t: unexpected status"
  [[ $(git -C "$t" remote get-url --push origin) == "$push" ]] || fail "$t: push url"
  [[ ! -e $t-checkout ]] || fail "$t: temp dir left behind"
  if [[ $hook == nohook ]]; then
    [[ ! -e $work/hook ]] || fail "$t: hook ran without one"
  else
    [[ $(cat "$work/hook") == "$t" ]] || fail "$t: hook did not run in the checkout"
    rm "$work/hook"
  fi
}

# A path that must stay as it is: refused with exit != 0, $1 unchanged
expect_unchanged() {
  local t="$1" name="$2"
  shift 2
  rm -rf "$work/before"
  cp -a "$t" "$work/before"
  if "$@" 2>"$work/err"; then
    fail "$name: exited 0"
  fi
  diff -r "$work/before" "$t" || fail "$name: changed $t"
  [[ ! -e $work/hook ]] || fail "$name: hook ran"
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
touch "$t-checkout/.nix-config-checkout"
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

# Without a hook (servers) and with a trailing slash
t="$HOME/nohook"
installer_copy "$t"
"$checkout" "$t/" "$url" "$push"
expect_checkout "$t" nohook

# No flake.nix: not install-host's copy, left alone
t="$HOME/noflake"
mkdir "$t"
echo mine >"$t/file"
cp -a "$t" "$work/noflake.before"
run "$t" "$url" "$push"
diff -r "$work/noflake.before" "$t" || fail "target without flake.nix changed"
[[ ! -e $t/.git && ! -e $t-checkout && ! -e $work/hook ]] || fail "target without flake.nix: acted on"

# A leftover of ours next to a checkout (killed after the swap) is removed;
# the checkout stays as it is
t="$HOME/leftover"
git clone --quiet "$url" "$t"
mkdir "$t-checkout"
touch "$t-checkout/.nix-config-checkout"
run "$t" "$url" "$push"
[[ ! -e $t-checkout ]] || fail "our leftover next to a checkout was kept"
[[ -z $(git -C "$t" status --porcelain) && ! -e $work/hook ]] || fail "checkout with leftover touched"

# Something at <target>-checkout that is not ours: refused, kept, target unchanged
for kind in dir file symlink; do
  t="$HOME/foreign-$kind"
  installer_copy "$t"
  case $kind in
    dir) mkdir "$t-checkout" && echo mine >"$t-checkout/data" ;;
    file) echo mine >"$t-checkout" ;;
    symlink)
      mkdir "$work/elsewhere"
      touch "$work/elsewhere/.nix-config-checkout"
      ln -s "$work/elsewhere" "$t-checkout"
      ;;
  esac
  cp -a "$t-checkout" "$work/foreign-$kind.before"
  expect_unchanged "$t" "foreign $kind" run "$t" "$url" "$push"
  grep -q "FAILED.*during: prepare" "$work/err" || fail "foreign $kind: step not named: $(cat "$work/err")"
  diff -r --no-dereference "$work/foreign-$kind.before" "$t-checkout" || fail "foreign $kind was changed"
done
[[ -e $work/elsewhere/.nix-config-checkout ]] || fail "symlink target was emptied"

# A failing hook: exit != 0 naming the hook step; the checkout stays in place
t="$HOME/hookfails"
installer_copy "$t"
if "$checkout" "$t" "$url" "$push" sh -c 'pwd >"$0"; exit 3' "$work/hook" 2>"$work/err"; then
  fail "a failing hook exited 0"
fi
grep -q "FAILED (exit 3) during: run sh" "$work/err" || fail "failed hook not reported: $(cat "$work/err")"
grep -q "is a checkout already" "$work/err" || fail "failed hook: state not reported"
expect_checkout "$t"

# SIGTERM during the hook (systemd stops the unit) still names the step
t="$HOME/term"
installer_copy "$t"
"$checkout" "$t" "$url" "$push" sh -c 'echo $$ >"$0"; exec sleep 60' "$work/hookpid" 2>"$work/err" &
pid=$!
for _ in $(seq 100); do
  [[ -s $work/hookpid ]] && break
  sleep 0.1
done
[[ -s $work/hookpid ]] || fail "hook did not start"
kill -TERM "$pid"
kill -TERM "$(cat "$work/hookpid")"
if wait "$pid"; then
  fail "a killed run exited 0"
fi
grep -q "FAILED (exit 143) during: run sh" "$work/err" || fail "SIGTERM not reported: $(cat "$work/err")"
[[ ! -e $t-checkout ]] || fail "SIGTERM left the temp dir"

echo "nix-config-checkout: all tests passed"
