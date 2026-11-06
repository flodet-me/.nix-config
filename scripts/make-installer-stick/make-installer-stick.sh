# shellcheck shell=bash
# Builds the installer ISO and writes it to a USB stick, then verifies it.
# Refuses anything that is not a removable USB disk.
#
# usage: make-installer-stick [--iso FILE] [/dev/sdX]

iso=""
dev=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)
      iso="$2"
      shift 2
      ;;
    -h | --help)
      echo "usage: make-installer-stick [--iso FILE] [/dev/sdX]" >&2
      exit 1
      ;;
    *)
      dev="$1"
      shift
      ;;
  esac
done

if [[ -z $iso ]]; then
  repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/.nix-config")
  echo "==> Building the installer ISO from $repo"
  out=$(nix build --no-link --print-out-paths "$repo#installer-iso")
  iso=$(echo "$out"/iso/*.iso)
fi
[[ -f $iso ]] || {
  echo "no ISO at $iso" >&2
  exit 1
}
iso_size=$(stat -L -c %s "$iso")
echo "ISO: $iso ($((iso_size / 1024 / 1024 / 1024)) GiB)"

usb_disks() { lsblk -dnpo NAME,TRAN,RM | awk '$2 == "usb" && $3 == 1 { print $1 }'; }

if [[ -z $dev ]]; then
  mapfile -t candidates < <(usb_disks)
  case ${#candidates[@]} in
    0)
      echo "no removable USB disk found" >&2
      exit 1
      ;;
    1) dev=${candidates[0]} ;;
    *)
      lsblk -dpo NAME,SIZE,MODEL "${candidates[@]}"
      read -r -p "Which device? " dev
      ;;
  esac
fi

usb_disks | grep -qx "$dev" || {
  echo "$dev is not a removable USB disk, refusing" >&2
  exit 1
}
dev_size=$(lsblk -dnbo SIZE "$dev")
((dev_size >= iso_size)) || {
  echo "$dev is too small" >&2
  exit 1
}

echo
lsblk -po NAME,SIZE,MODEL,FSTYPE,LABEL,MOUNTPOINTS "$dev"
echo
echo "EVERYTHING on $dev will be erased."
read -r -p "Type the device name ($dev) to continue: " confirm
[[ $confirm == "$dev" ]] || {
  echo "aborted" >&2
  exit 1
}

# Unmount partitions the desktop auto-mounted
for part in $(lsblk -lnpo NAME,MOUNTPOINTS "$dev" | awk 'NF > 1 { print $1 }'); do
  udisksctl unmount -b "$part" >/dev/null 2>&1 || sudo umount "$part"
done

echo "==> Writing (needs sudo)"
sudo dd if="$iso" of="$dev" bs=4M oflag=direct conv=fsync status=progress
echo "==> Verifying"
sudo cmp -n "$iso_size" "$iso" "$dev"
echo "OK: $dev verified. Boot it with UEFI and run: sudo install-host <host>"
