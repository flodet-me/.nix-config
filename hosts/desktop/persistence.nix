{ ... }:
{
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
    ];
  };
}
