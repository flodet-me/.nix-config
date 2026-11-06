# shellcheck shell=bash
# Adds (or replaces) a host's age key in .sops.yaml and re-encrypts the
# secrets files it may read, using the YubiKey. Used directly, by install-host
# and by provision-server.
#
#   workstation (default): may read hosts/_shared/** and home/** secrets
#   --server:              may read only hosts/<host>/secrets.yaml (own rule)

usage() {
  cat >&2 <<'EOF'
usage: sops-register-host [--server] [--repo DIR] [--verify-key KEYFILE] <host> <age-pubkey>
  --server            own rule for hosts/<host>/secrets.yaml instead of the shared secrets
  --repo DIR          repo checkout (default: the git repo of the current dir)
  --verify-key FILE   private key of the host: check it decrypts its files
EOF
  exit 1
}

repo=""
verify_key=""
server=no
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
    --server)
      server=yes
      shift
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
repo="${repo:-$(git rev-parse --show-toplevel)}"
cd "$repo"
cfg=.sops.yaml

# keys:  `  - &host age1...`  (replace, uncomment a placeholder, or append)
if grep -qE "^  - &$host age1" "$cfg"; then
  sed -i -E "s|^  - &$host age1[a-z0-9]+|  - \&$host $pubkey|" "$cfg"
elif grep -qE "^  # - &$host " "$cfg"; then
  sed -i -E "s|^  # - &$host .*|  - \&$host $pubkey|" "$cfg"
else
  last=$(grep -nE '^  - &[a-z0-9-]+ age1' "$cfg" | tail -1 | cut -d: -f1)
  sed -i "${last}a\\  - \&$host $pubkey" "$cfg"
fi

if [[ $server == yes ]]; then
  # own rule, inserted below the marker comment
  if ! grep -qF "  - path_regex: hosts/$host/secrets" "$cfg"; then
    marker=$(grep -n "are inserted here by .sops-register-host --server." "$cfg" | cut -d: -f1)
    [[ -n $marker ]] || {
      echo "marker comment for server rules missing in $cfg" >&2
      exit 1
    }
    sed -i "${marker}r /dev/stdin" "$cfg" <<EOF
  - path_regex: hosts/$host/secrets\\.(yaml|json|env|ini)\$
    key_groups:
      - pgp:
          - *flodet
        age:
          - *$host
EOF
  fi
  mapfile -t files < <(find "hosts/$host" -name '*secrets.yaml' | sort)
else
  # recipient in the shared (workstation) rule
  rule=$(grep -nF "  - path_regex: (hosts/_shared|home)/" "$cfg" | cut -d: -f1)
  [[ -n $rule ]] || {
    echo "shared rule missing in $cfg" >&2
    exit 1
  }
  age_line=$(awk -v r="$rule" 'NR > r && /^        age:$/ { print NR; exit }' "$cfg")
  awk -v r="$rule" -v h="          - *$host" '
    NR > r && /^  - path_regex:/ { exit }
    NR > r && $0 == h { found = 1 }
    END { exit !found }' "$cfg" ||
    sed -i "${age_line}a\\          - *$host" "$cfg"
  mapfile -t files < <(find hosts/_shared home -name '*secrets.yaml' | sort)
fi

# Make the YubiKey PIN prompt appear in this terminal (not some other one).
if tty -s; then
  GPG_TTY=$(tty)
  export GPG_TTY
  gpg-connect-agent updatestartuptty /bye >/dev/null || true
fi

failed=0
for f in "${files[@]}"; do
  echo "re-encrypting $f"
  sops updatekeys -y "$f" || failed=1
  if [[ -n $verify_key ]]; then
    # only the new key: no gpg, and not ~/.config/sops/age/keys.txt either
    env -u SOPS_AGE_KEY HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent GNUPGHOME=/nonexistent \
      SOPS_AGE_KEY_FILE="$verify_key" sops decrypt "$f" >/dev/null ||
      {
        echo "  the new key can NOT decrypt $f" >&2
        failed=1
      }
  elif ! grep -q "recipient: $pubkey" "$f"; then
    echo "  $f does not list the new key" >&2
    failed=1
  fi
done

if [[ $failed -ne 0 ]]; then
  echo "FAILED. If gpg said 'Invalid ID' the PIN prompt timed out, see docs/secrets.md" >&2
  exit 1
fi
echo "OK: $host registered, it can read ${#files[@]} secrets file(s). Commit .sops.yaml and the secrets files."
