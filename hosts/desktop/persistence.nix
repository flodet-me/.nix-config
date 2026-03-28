{ ... }:
{
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    mkdir /btrfs_tmp
    mount /dev/mapper/enc /btrfs_tmp
    if [[ -e /btrfs_tmp/@root ]]; then
      mkdir -p /btrfs_tmp/@root-old
      timestamp=$(date --date="@$(stat -c %Y /btrfs_tmp/@root)" "+%Y-%m-%d_%H:%M:%S")
      mv /btrfs_tmp/@root "/btrfs_tmp/@root-old/$timestamp"
    fi
    btrfs subvolume create /btrfs_tmp/@root
    umount /btrfs_tmp
    rmdir /btrfs_tmp
  '';

  fileSystems."/persistent".neededForBoot = true;

  environment.persistence."/persistent" = {
    hideMounts = true;
    directories = [
      # System state
      "/var/log"
      "/var/lib/nixos"
      {
        directory = "/var/lib/systemd";
        user = "root";
        group = "root";
        mode = "0755";
      }

      # Networking
      "/etc/NetworkManager/system-connections"

      # Bluetooth
      "/var/lib/bluetooth"

      # Docker
      "/var/lib/docker"

      # Libvirt / VMs
      "/var/lib/libvirt"

      # Printing
      "/var/lib/cups"

      # Mullvad VPN
      "/etc/mullvad-vpn"

      # Yubikey / GPG
      "/etc/ssh"

      # LUKS / cryptsetup
      "/var/lib/systemd/luksrecoverykey"
    ];
    files = [
      "/etc/machine-id"
    ];
  };
}
