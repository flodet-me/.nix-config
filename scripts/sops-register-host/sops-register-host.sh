# shellcheck shell=bash
# Adds or replaces a host's age key (keys/hosts/<host>.age, by host name, so a
# reinstall replaces the old key) and runs sops-sync: .sops.yaml is regenerated
# and the secrets the host may read (by its host.role) are re-encrypted with the
# YubiKey. Used directly, by install-host and by provision-server.
#
# usage: sops-register-host [--repo DIR] [--verify-key KEYFILE] <host> <age-pubkey>

usage() {
  cat >&2 <<'EOF'
usage: sops-register-host [--repo DIR] [--verify-key KEYFILE] <host> <age-pubkey>
  --repo DIR          repo checkout (default: the git repo of the current dir)
  --verify-key FILE   private key of the host: check it decrypts its files
EOF
  exit 1
}

repo=""
verify_key=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="$2"
      shift 2
      ;;
    --verify-key)
      verify_key="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    *) break ;;
  esac
done
[[ $# -eq 2 ]] || usage
host="$1"
pubkey="$2"
[[ $host =~ ^[a-z0-9-]+$ ]] || {
  echo "invalid host name: $host" >&2
  exit 1
}
[[ $pubkey =~ ^age1[a-z0-9]{58}$ ]] || {
  echo "not an age public key: $pubkey" >&2
  exit 1
}
cd "${repo:-$(git rev-parse --show-toplevel)}" || exit 1

echo "$pubkey" >"keys/hosts/$host.age"
if [[ -n $verify_key ]]; then
  sops-sync --verify "$host" "$verify_key"
else
  sops-sync
fi
