# shellcheck shell=bash
# Try the installer in a QEMU window before writing a stick: boots the ISO
# with a blank NVMe disk (UEFI), or with --boot the installed disk.
# State (disk, UEFI vars) lives in ~/.cache/installer-vm.
#
# usage: installer-vm [--iso FILE] [--boot] [--fresh] [--size 64G]

state="${XDG_CACHE_HOME:-$HOME/.cache}/installer-vm"
iso=""
boot_disk=no
fresh=no
size=64G
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)
      iso="$2"
      shift 2
      ;;
    --boot)
      boot_disk=yes
      shift
      ;;
    --fresh)
      fresh=yes
      shift
      ;;
    --size)
      size="$2"
      shift 2
      ;;
    *)
      echo "usage: installer-vm [--iso FILE] [--boot] [--fresh] [--size 64G]" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$state"
if [[ $fresh == yes ]]; then
  rm -f "$state/disk.qcow2" "$state/vars.fd"
fi
[[ -e $state/disk.qcow2 ]] || qemu-img create -f qcow2 "$state/disk.qcow2" "$size" >/dev/null
[[ -e $state/vars.fd ]] || install -m 644 "@ovmf@/FV/OVMF_VARS.fd" "$state/vars.fd"

args=(
  -enable-kvm -cpu host -m 6144 -smp 4 -machine q35
  -drive "if=pflash,format=raw,readonly=on,file=@ovmf@/FV/OVMF_CODE.fd"
  -drive "if=pflash,format=raw,file=$state/vars.fd"
  -drive "file=$state/disk.qcow2,if=none,id=nvm" -device "nvme,serial=installer-vm,drive=nvm"
  -nic "user,model=virtio-net-pci"
)
if [[ $boot_disk == no ]]; then
  if [[ -z $iso ]]; then
    repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/.nix-config")
    iso=$(echo "$(nix build --no-link --print-out-paths "$repo#installer-iso")"/iso/*.iso)
  fi
  args+=(-cdrom "$iso" -boot order=d)
  echo "Installer VM: blank NVMe disk is /dev/nvme0n1 (what the laptop config expects)."
fi
exec qemu-system-x86_64 "${args[@]}"
