# shellcheck shell=bash
# First install of a server from this flake onto a fresh (cloud) machine, via
# nixos-anywhere. The server's keys are created here, so its secrets work from
# the first boot and its SSH host key is pinned before we ever connect.
#
# usage: provision-server <host> <root@ip> [extra nixos-anywhere args, e.g. --ssh-port 2222]
#   <root@ip>  any Linux reachable as root over SSH (e.g. Hetzner rescue
#              system or a stock Ubuntu image); its disk gets WIPED.
# See docs/cloud.md.

[[ $# -ge 2 ]] || {
  echo "usage: provision-server <host> <root@ip> [nixos-anywhere args...]" >&2
  exit 1
}
host="$1"
target="$2"
shift 2
repo=$(git rev-parse --show-toplevel)
cd "$repo"
[[ -f hosts/$host/default.nix ]] || {
  echo "hosts/$host/default.nix does not exist" >&2
  exit 1
}
nix eval --raw ".#nixosConfigurations.$host.config.networking.hostName" >/dev/null || {
  echo "nixosConfigurations.$host is missing in flake.nix" >&2
  exit 1
}

# Ask first: nothing (keys, repo files) is created for a run that is aborted
echo "The disk of $target will be WIPED and $host installed."
read -r -p "Type the host name ($host) to continue: " confirm
[[ $confirm == "$host" ]] || {
  echo "aborted, nothing was changed" >&2
  exit 1
}

phase="starting"
step() {
  phase="$1"
  echo "==> $1"
}

tmp=$(mktemp -d)
cleanup() {
  local rc=$?
  find "$tmp" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$tmp"
  if ((rc != 0)); then
    echo >&2
    echo "provision-server FAILED (exit $rc) during: $phase" >&2
    echo "The generated private keys are gone with the temp dir. The repo may already hold" >&2
    echo "their public halves (keys/hosts/$host.age, .sops.yaml, hosts/$host/ssh_host_ed25519_key.pub)." >&2
    echo "Run provision-server again (new keys replace them), or undo: git checkout .sops.yaml keys hosts/$host" >&2
  fi
}
trap cleanup EXIT
extra="$tmp/extra"
sops_key_path=@sopsKey@ # where the host reads its age key (impermanence/names.nix)
sops_dir=$(dirname "$sops_key_path")
install -d -m 700 "$extra$sops_dir" "$extra/persist/etc/ssh"

step "Generating the server's keys locally"
sops_key="$extra$sops_key_path"
(umask 077 && age-keygen -o "$sops_key" 2>/dev/null)
ssh-keygen -q -t ed25519 -N "" -C "root@$host" -f "$extra/persist/etc/ssh/ssh_host_ed25519_key"

step "Registering the sops key (keys/hosts/$host.age, role from its config)"
sops-register-host --verify-key "$sops_key" "$host" "$(age-keygen -y "$sops_key")"

step "Pinning the SSH host key"
cp "$extra/persist/etc/ssh/ssh_host_ed25519_key.pub" "hosts/$host/ssh_host_ed25519_key.pub"
git add --intent-to-add "hosts/$host/ssh_host_ed25519_key.pub"

step "Installing $host with nixos-anywhere (wipes the disk)"
nixos-anywhere \
  --flake ".#$host" \
  --target-host "$target" \
  --extra-files "$extra" \
  --chown "$sops_dir" 0:0 \
  --chown /persist/etc/ssh 0:0 \
  "$@"

cat <<EOF

Done. Next steps:
  * set the address of $host in hosts/_shared/components/server-access.nix
  * commit keys/hosts/$host.age, .sops.yaml, hosts/$host/ (incl. ssh_host_ed25519_key.pub), push
  * rebuild your workstation, then: ssh $host
  * updates later: nixos-rebuild switch --flake .#$host --target-host $host --sudo
EOF
