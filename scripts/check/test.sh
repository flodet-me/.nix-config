# shellcheck shell=bash
# Tests for check (and gate = check --gate), run while building it
# (scripts/default.nix). A stub nix on PATH records its calls and fails the
# call that matches $NIX_FAIL (an extended regex), so nothing is built.
# usage: test.sh <path to check>
set -euo pipefail
check="$1"
work=$(mktemp -d)
mkdir "$work/bin" "$work/repo" "$work/empty"
touch "$work/repo/flake.nix"
# No /usr/bin/env in the build sandbox: the shebang names this bash
echo "#!$BASH" >"$work/bin/nix"
cat >>"$work/bin/nix" <<'STUB'
echo "$*" >>"$NIX_CALLS"
if [[ -n ${NIX_FAIL:-} && "$*" =~ $NIX_FAIL ]]; then exit 1; fi
case "$*" in
  *builtins.currentSystem*) printf x86_64-linux ;;
  *nixosConfigurations*attrNames*) printf '%s' "$NIX_HOSTS" ;;
esac
STUB
chmod +x "$work/bin/nix"
export PATH="$work/bin:$PATH" NIX_CALLS="$work/calls" NIX_HOSTS="h1 h2"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# run <dir> <args...>: rc, calls and output (stdout+stderr) of one run
run() {
  local dir="$1"
  shift
  : >"$NIX_CALLS"
  rc=0
  (cd "$dir" && "$check" "$@") >"$work/out" 2>&1 || rc=$?
}
called() { grep -qxE -- "$1" "$NIX_CALLS"; }
said() { grep -qE -- "$1" "$work/out"; }

# Without ./flake.nix: refused, nix never called
run "$work/empty"
((rc != 0)) || fail "no flake.nix: exited 0"
said "flake.nix" || fail "no flake.nix: no reason given: $(cat "$work/out")"
[[ ! -s $NIX_CALLS ]] || fail "no flake.nix: nix was called: $(cat "$NIX_CALLS")"

# Unknown argument: refused
run "$work/repo" --bogus
((rc != 0)) || fail "unknown argument: exited 0"

# Check: the fast builds and the evaluation, from the flake in . (no jail)
run "$work/repo"
((rc == 0)) || fail "check exited $rc: $(cat "$work/out")"
for c in formatting scripts sops-encrypted; do
  called "build --no-link \.#checks\.x86_64-linux\.$c" || fail "check: $c not built"
done
called "build --no-link \.#install-host" || fail "check: install-host not built"
called "flake check --no-build" || fail "check: flake not evaluated"
! called ".*jail.*" || fail "check: jail test ran without --jail"

# --jail adds the jail VM test
run "$work/repo" --jail
((rc == 0)) || fail "check --jail exited $rc: $(cat "$work/out")"
called "build --no-link \.#checks\.x86_64-linux\.jail" || fail "check --jail: no jail test"

# A failing step: named, exit != 0, later steps not run
NIX_FAIL='checks\.x86_64-linux\.scripts' run "$work/repo"
((rc != 0)) || fail "failing step: exited 0"
said "FAILED \(exit 1\) during: build checks\.x86_64-linux\.scripts" ||
  fail "failing step not named: $(cat "$work/out")"
! called ".*sops-encrypted.*" || fail "failing step: later steps ran"

# Gate: the full flake check (it builds), install-host and every host
run "$work/repo" --gate
((rc == 0)) || fail "gate exited $rc: $(cat "$work/out")"
called "flake check" || fail "gate: no full nix flake check"
called "build --no-link \.#install-host" || fail "gate: install-host not built"
for h in h1 h2; do
  called "build --no-link \.#nixosConfigurations\.$h\.config\.system\.build\.toplevel" ||
    fail "gate: host $h not built"
done

# Gate, failing host: named, exit != 0
NIX_FAIL='nixosConfigurations\.h1\.' run "$work/repo" --gate
((rc != 0)) || fail "failing host: exited 0"
said "FAILED \(exit 1\) during: build host h1" || fail "failing host not named: $(cat "$work/out")"
! called ".*\.h2\..*" || fail "failing host: next host built"

# Gate, host list fails to evaluate or is empty: never green
NIX_FAIL='attrNames' run "$work/repo" --gate
((rc != 0)) || fail "host list eval failed: exited 0"
said "FAILED \(exit 1\) during: list hosts" || fail "host list failure not named: $(cat "$work/out")"
NIX_HOSTS="" run "$work/repo" --gate
((rc != 0)) || fail "empty host list: exited 0"
said "FAILED .*during: list hosts" || fail "empty host list not named: $(cat "$work/out")"

echo "check: all tests passed"
