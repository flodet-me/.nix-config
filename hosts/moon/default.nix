# Home server: DNS resolver with ad blocking (./dns.nix) and containers for
# home services. Server base: YubiKey-only SSH, hardening, impermanent btrfs
# root, backups (docs/cloud.md applies here as well). Install from the stick:
# `sudo install-host moon` (docs/installer.md).
{
  inputs,
  ...
}:
{
  imports = [
    inputs.hardware.nixosModules.common-cpu-intel
    inputs.hardware.nixosModules.common-pc-ssd

    ./hardware-configuration.nix
    ../_shared/global.nix
    ../_shared/components/server
    # Unencrypted: an unattended home server must come back after a power cut
    # without someone typing a passphrase.
    (import ../_shared/components/impermanence/disko.nix {
      device = "/dev/disk/by-id/ata-UDSS_UD2CS1HT100-512G_TUSMA24BVX00720";
      swapSize = "4G";
      encrypt = false;
    })
    ../_shared/components/uefi-boot.nix
    ./dns.nix
    ./firewall.nix
    ./ntp.nix
  ];

  networking.hostName = "moon";

  # DHCP with a fixed lease in the router: 10.0.0.2 (server-access.nix and
  # dns.nix use it), it is the network's DNS and NTP server
  networking.useDHCP = true;
  # Fixed IPv6 host part ::2 on every prefix the router announces, so the
  # address is known in advance: fd00::2 with the Fritz!Box ULA prefix
  # fd00::/64 (set it manually there), entered as its local DNSv6 server.
  # Sorts before NixOS' 99-ethernet-default-dhcp, which it replaces.
  systemd.network.networks."10-lan" = {
    matchConfig = {
      Type = "ether";
      Kind = "!*";
    };
    networkConfig.DHCP = "yes";
    ipv6AcceptRAConfig.Token = "static:::2";
  };

  # Hardware watchdog: if the kernel hangs, the board resets moon instead of
  # leaving the network without DNS (Intel TCO watchdog, iTCO_wdt).
  systemd.settings.Manager.RuntimeWatchdogSec = "30s";

  # Home services as containers (state in /var/lib/containers: kept, backed up)
  virtualisation = {
    containers.enable = true;
    podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true; # containers under podman-compose can talk to each other
    };
    # Container DNS (aardvark-dns) can't bind :53 next to blocky; podman
    # redirects the containers' port 53 to this one instead.
    containers.containersConf.settings.network.dns_bind_port = 1153;
  };
  networking.firewall.interfaces."podman*" = {
    allowedUDPPorts = [ 1153 ];
    allowedTCPPorts = [ 1153 ];
  };

  # Backups: add the restic-* keys to hosts/moon/secrets.yaml first (docs/cloud.md)
  backup = {
    enable = false;
    secretsFile = ./secrets.yaml;
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. Leave it at the first install's release.
  system.stateVersion = "26.11"; # first install of the reinstalled system
}
