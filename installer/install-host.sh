# shellcheck shell=bash
# Installs one of this flake's hosts (any with a disko layout) onto a blank
# machine: disko -> sops host key -> register it with the YubiKey ->
# nixos-install. See docs/installer.md.
#
# usage: sudo install-host <host> [--disk /dev/XXX]

repo_src="@repo@"
installable="@hosts@"
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
[[ " $installable " == *" $host "* && -n $host ]] ||
  die "usage: install-host <host> [--disk /dev/XXX]   (hosts on this stick: $installable)"
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
# Always recorded, also if registering fails below: sops-sync can do it later
echo "$pubkey" >"$work/keys/hosts/$host.age"

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

step "Putting the config into ~/.nix-config"
home=/mnt/home/flodet
checkout="$home/.nix-config"
# What this install adds to the repo: only the host's key (and the disk, if
# --disk was given). Everything else comes from GitHub's current state, so a
# stick that is older than the repo never overwrites newer secrets.
keep=("keys/hosts/$host.age")
[[ -n $disk ]] && keep+=("hosts/$host/default.nix")
# shellcheck disable=SC2088 # the ~ in the messages is meant literally
if [[ -d $checkout/.git ]]; then
  # restored backup with a checkout: put the files there
  (cd "$work" && cp --parents "${keep[@]}" "$checkout/")
  how="In your restored ~/.nix-config (YubiKey plugged in): sops-sync && git add -A && git commit -m \"$host: register sops key\" && git push"
elif [[ ! -e $checkout ]]; then
  # becomes a git checkout on the first login (user service nix-config-checkout)
  cp -r "$work" "$checkout"
  printf '%s\n' "${keep[@]}" >"$checkout/.install-keep"
  how="Automatic on the first login with network and the YubiKey plugged in: ~/.nix-config becomes a checkout of GitHub's main plus this host's key, re-encrypted (PIN prompt) and committed. Then just: cd ~/.nix-config && git push"
else
  mkdir -p "$home/install-$host"
  (cd "$work" && cp --parents "${keep[@]}" "$home/install-$host/")
  how="~/.nix-config exists but isn't a git checkout: copy ~/install-$host/* into your checkout, run sops-sync, commit and push"
fi
chown -R 1000:100 "$home" 2>/dev/null || true

cat <<EOF

Done. Reboot, remove the stick, log in, plug in the YubiKey.
$how
EOF
if [[ $registered == no ]]; then
  cat <<EOF
Note: the secrets were NOT re-encrypted for $host yet, so they are missing until
that step has run and you rebuilt: sudo nixos-rebuild switch --flake ~/.nix-config#$host
EOF
fi
