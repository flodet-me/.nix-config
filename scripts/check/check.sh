# shellcheck shell=bash
# The project's Check and Gate (CLAUDE.md `## Factory`, docs/testing.md), the
# one copy of both lists. Builds the flake of the current directory, never a
# store copy of it (that would test a stale tree), so run it from the
# repository root. Each step is announced; a failure names it and exits != 0.
#
# usage: check [--jail]   fast: formatting, scripts, sops-encrypted, install-host,
#                         nix flake check --no-build; --jail adds the jail VM test
#        check --gate     full (`gate`): nix flake check (builds every check, the
#                         jail VM test too), install-host, every host's toplevel
# nix itself comes from the system (same version as the store).

usage() {
  echo "usage: check [--jail] | check --gate" >&2
  exit 1
}
gate=false
jail=false
for arg in "$@"; do
  case "$arg" in
    --gate) gate=true ;;
    --jail) jail=true ;;
    *) usage ;;
  esac
done
name=check
if $gate; then name=gate; fi

if [[ ! -f flake.nix ]]; then
  echo "$name: no ./flake.nix in $PWD; run it from the repository root" >&2
  exit 1
fi

phase="starting"
step() {
  phase="$1"
  echo "==> $1" >&2
}
on_exit() {
  local rc=$?
  ((rc == 0)) || echo "$name FAILED (exit $rc) during: $phase" >&2
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

step "detect system"
sys=$(nix eval --impure --raw --expr builtins.currentSystem)

if $gate; then
  step "nix flake check"
  nix flake check
  step "build install-host"
  nix build --no-link .#install-host
  step "list hosts"
  hosts=$(nix eval --raw .#nixosConfigurations --apply 'cs: toString (builtins.attrNames cs)')
  if [[ -z $hosts ]]; then
    echo "no hosts in nixosConfigurations" >&2
    exit 1
  fi
  for host in $hosts; do
    step "build host $host"
    nix build --no-link ".#nixosConfigurations.$host.config.system.build.toplevel"
  done
else
  for c in formatting scripts sops-encrypted; do
    step "build checks.$sys.$c"
    nix build --no-link ".#checks.$sys.$c"
  done
  step "build install-host"
  nix build --no-link .#install-host
  step "nix flake check --no-build"
  nix flake check --no-build
  if $jail; then
    step "build checks.$sys.jail"
    nix build --no-link ".#checks.$sys.jail"
  fi
fi
echo "$name passed" >&2
