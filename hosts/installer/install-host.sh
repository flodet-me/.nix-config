# shellcheck shell=bash
# Installs one of this flake's impermanent hosts onto a blank machine:
# disko (LUKS + btrfs) -> sops host key -> register it with the YubiKey ->
# nixos-install. See docs/installer.md.
#
# usage: sudo install-host <desktop|laptop> [--disk /dev/XXX]

repo_src="@repo@"
work=/tmp/nix-config

die() {
  echo "error: $*" >&2
  exit 1
}
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ask() {
  local reply
  read -r -p "$1 [y/N] " reply
  [[ $reply == [yY]* ]]
}

[[ $EUID -eq 0 ]] || die "run as root: sudo install-host $*"
host="${1:-}"
[[ $host == desktop || $host == laptop ]] || die "usage: install-host <desktop|laptop> [--disk /dev/XXX]"
shift
disk=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk)
      disk="${2:-}"
      shift 2
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

step "Preparing a writable copy of the config in $work"
if [[ -e $work ]]; then
  echo "$work exists (from an earlier run), reusing it"
else
  cp -r --no-preserve=mode "$repo_src" "$work"
fi
hostcfg="$work/hosts/$host/default.nix"

if [[ -n $disk ]]; then
  [[ -b $disk ]] || die "$disk is not a block device"
  sed -i -E "s|^(\s*device = )\"[^\"]*\";|\1\"$disk\";|" "$hostcfg"
fi
target=$(grep -oP '^\s*device = "\K[^"]+' "$hostcfg")
[[ -b $target ]] || die "configured disk $target does not exist here; pick one from lsblk and pass --disk /dev/XXX"

step "Target disk for $host: $target -> $(readlink -f "$target")"
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,FSTYPE,LABEL "$(readlink -f "$target")"
echo
echo "EVERYTHING on this disk will be erased."
read -r -p "Type the host name ($host) to continue: " confirm
[[ $confirm == "$host" ]] || die "aborted"

step "Partitioning and formatting (you will be asked for the new LUKS passphrase)"
disko --mode destroy,format,mount --yes-wipe-all-disks --flake "$work#$host"
mountpoint -q /mnt/persist || die "/mnt/persist is not mounted after disko"

step "Generating the sops host key"
keyfile=/mnt/persist/var/lib/sops-nix/key.txt
install -d -m 700 "$(dirname "$keyfile")"
if [[ -s $keyfile ]]; then
  echo "keeping existing key $keyfile"
else
  (umask 077 && age-keygen -o "$keyfile" 2>/dev/null)
fi
pubkey=$(age-keygen -y "$keyfile")
echo "public key: $pubkey"

mapfile -t secret_files < <(cd "$work" && find hosts home -name '*secrets.yaml' | sort)

step "Registering the key (YubiKey)"
registered=no
if ask "Register the new key and re-encrypt the secrets now? Needs the YubiKey plugged in."; then
  install -d -m 700 /root/.gnupg
  echo "disable-ccid" >/root/.gnupg/scdaemon.conf
  gpg --quiet --import "$work/keys/flodet.asc"
  if ! gpg --card-status >/dev/null 2>&1; then
    echo "WARNING: no YubiKey found (gpg --card-status failed), continuing without secrets"
  elif sops-register-host --repo "$work" --verify-key "$keyfile" "$host" "$pubkey"; then
    registered=yes
  else
    echo "WARNING: registering failed (see above), continuing without secrets"
    # undo the half-done registration
    (cd "$work" && for f in .sops.yaml "${secret_files[@]}"; do cp --no-preserve=mode "$repo_src/$f" "$f"; done)
  fi
fi

if ask "Pause to restore data into /mnt (e.g. rsync a backup into /mnt/home) from another terminal?"; then
  read -r -p "Press Enter when done. "
fi

step "Building the system ($host)"
# Build in the installer's own store, where all inputs and closures from the
# stick already are. (`nixos-install --flake` would evaluate against the empty
# /mnt store and try to download every flake input.)
system=$(nix --extra-experimental-features "nix-command flakes" build --no-link --print-out-paths \
  --option connect-timeout 5 --option fallback true \
  "$work#nixosConfigurations.$host.config.system.build.toplevel")

step "Installing NixOS ($host)"
nixos-install --system "$system" --no-root-passwd --no-channel-copy

step "Saving the updated config for committing"
save="/mnt/home/flodet/sops-registration-$host-$(date +%Y%m%d-%H%M)"
mkdir -p "$save"
(cd "$work" && cp --parents .sops.yaml "${secret_files[@]}" "$save/")
if [[ ! -e /mnt/home/flodet/.nix-config ]]; then
  cp -r "$work" /mnt/home/flodet/.nix-config
  chown -R 1000:100 /mnt/home/flodet/.nix-config
fi
chown -R 1000:100 "$save"

cat <<EOF

Done. Next steps:
  * reboot (remove the stick)
  * copy the files in ~/$(basename "$save") into your checkout of the repo
    (.sops.yaml and the secrets files), commit and push
EOF
if [[ $registered == no ]]; then
  cat <<EOF
  * secrets are NOT available yet. On a machine with the YubiKey, in the repo:
      sops-register-host $host $pubkey
    then commit, push and run
      sudo nixos-rebuild switch --flake .#$host   (on $host)
EOF
fi
