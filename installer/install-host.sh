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
current="starting" # the step that is running, named when something fails
step() {
  current="$*"
  printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

# Releases what disko mounted. An active swap file keeps btrfs busy, and the
# live system's shutdown then loops on unmounting /mnt and closing LUKS.
teardown() {
  sync
  swapon --noheadings --show=NAME | grep '^/mnt/' | xargs -r swapoff || true
  umount -R /mnt 2>/dev/null || echo "warning: /mnt still mounted (check: findmnt -R /mnt)" >&2
  if [[ -e /dev/mapper/@luks@ ]]; then
    cryptsetup close @luks@ || echo "warning: could not close LUKS device @luks@" >&2
  fi
  # the data disk (data-disk.nix), if the host has one
  if [[ -e /dev/mapper/@dataLuks@ ]]; then
    cryptsetup close @dataLuks@ || echo "warning: could not close LUKS device @dataLuks@" >&2
  fi
  # the temporary key of the data disk must never outlive the run
  shred -u @dataKeyTmp@ 2>/dev/null || rm -f @dataKeyTmp@
}

# Any failure (or Ctrl-C) after the disk was touched ends here: say where it
# stopped and leave a clean state, so running install-host again just works.
disk_touched=no
finished=no
on_exit() {
  local rc=$?
  [[ $finished == yes || $rc -eq 0 ]] && return
  # a usage error before the first step explained itself already
  [[ $current == starting ]] && return
  echo >&2
  echo "install-host FAILED (exit $rc) during: $current" >&2
  if [[ $disk_touched == yes ]]; then
    echo "The disk of $host is half set up; nothing else was changed." >&2
    echo "Releasing /mnt and the encrypted disk so a new run starts clean." >&2
    echo "Run install-host again (it wipes the disk again). The error is above (Shift+PageUp)." >&2
    teardown || true
  fi
}
trap on_exit EXIT
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
# Always fresh: a copy left by an earlier run may carry its --disk edit
rm -rf "$work"
cp -r --no-preserve=mode "$repo_src" "$work"
hostcfg="$work/hosts/$host/default.nix"

if [[ -n $disk ]]; then
  [[ -b $disk ]] || die "$disk is not a block device"
  sed -i -E "s|^(\s*device = )\"[^\"]*\";|\1\"$disk\";|" "$hostcfg"
fi
# What disko will really wipe: the evaluated value, not a guess from the source
target=$(nix eval --raw "$work#nixosConfigurations.$host.config.disko.devices.disk.main.device") ||
  die "could not read the disk of $host from its disko layout"
[[ -b $target ]] || die "configured disk $target does not exist here; pick one from lsblk and pass --disk /dev/XXX"

# disko wipes every disk the layout declares (a data disk too), not only the
# system disk, so all of them are shown and must be there
mapfile -t all_disks < <(nix eval --raw "$work#nixosConfigurations.$host.config.disko.devices.disk" \
  --apply 'ds: builtins.concatStringsSep "\n" (map (d: d.device) (builtins.attrValues ds))')
for d in "${all_disks[@]}"; do
  [[ -b $d ]] || die "disk $d of $host does not exist here (plug it in, or remove it from the host's disko layout)"
done

step "Disks of $host that will be erased"
for d in "${all_disks[@]}"; do
  echo "$d -> $(readlink -f "$d")"
  lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,FSTYPE,LABEL "$(readlink -f "$d")"
done
echo
echo "EVERYTHING on ${#all_disks[@]} disk(s) above will be erased."
read -r -p "Type the host name ($host) to continue: " confirm
[[ $confirm == "$host" ]] || die "aborted"

step "Partitioning and formatting (you will be asked for the new LUKS passphrase)"
disk_touched=yes

# A host with a data disk (data-disk.nix) formats it with a random key that is
# stored on the encrypted system disk afterwards; it is needed during disko.
has_data=$(nix eval --raw "$work#nixosConfigurations.$host.config.disko.devices.disk" \
  --apply 'ds: if ds ? data then "yes" else "no"')
if [[ $has_data == yes ]]; then
  (umask 077 && head -c 64 /dev/urandom | base64 -w0 >@dataKeyTmp@)
fi

disko --mode destroy,format,mount --yes-wipe-all-disks --flake "$work#$host"
mountpoint -q /mnt/persist || die "/mnt/persist is not mounted after disko"
if [[ $has_data == yes ]]; then
  # The key is only needed again after boot: it lives on the encrypted system disk
  install -D -m 400 @dataKeyTmp@ "/mnt@dataKey@"
  shred -u @dataKeyTmp@
  echo "Data disk key stored in @dataKey@ on the encrypted system disk."
fi

step "Generating the sops host key"
keyfile=/mnt@sopsKey@
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

if ask "Pause to restore data into /mnt (e.g. rsync a backup into /mnt/home; a host with a data disk keeps its projects under /mnt/data) from another terminal?"; then
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
home=/mnt/home/@user@
checkout="$home/.nix-config"
# What this install adds to the repo: only the host's key (and the disk, if
# --disk was given). Everything else comes from GitHub's current state, so a
# stick that is older than the repo never overwrites newer secrets.
keep=("keys/hosts/$host.age")
[[ -n $disk ]] && keep+=("hosts/$host/default.nix")
role=$(nix eval --raw "$work#nixosConfigurations.$host.config.host.role")
# shellcheck disable=SC2088 # the ~ in the messages is meant literally
if [[ $role == server ]]; then
  # becomes a read-only checkout on the first boot with network (system
  # service nix-config-checkout, server/nix-config-checkout.nix)
  cp -r "$work" "$checkout"
  printf '%s\n' "${keep[@]}" >"$checkout/.install-keep"
  how="On the first boot with network ~/.nix-config becomes a checkout of GitHub's main, with this host's key as a local change. From your workstation: scp $host:.nix-config/keys/hosts/$host.age keys/hosts/ && sops-sync && git add -A && git commit -m \"$host: register sops key\" && git push, then deploy (docs/cloud.md)."
elif [[ -d $checkout/.git ]]; then
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
# The user's uid/gid: the first normal user (1000) in group users (100)
chown -R 1000:100 "$home" || echo "warning: could not chown $home to the user" >&2

step "Releasing /mnt and the encrypted disk"
teardown
finished=yes

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
