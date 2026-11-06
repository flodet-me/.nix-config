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
    # without someone typing a passphrase (TPM2 unlock: docs/cloud.md).
    (import ../_shared/components/impermanence/disko.nix {
      # TODO: check with `ls -l /dev/disk/by-id` on moon, or pass --disk to install-host
      device = "/dev/sda";
      swapSize = "4G";
      encrypt = false;
    })
    ./dns.nix
  ];

  networking.hostName = "moon";

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  # DHCP; give moon a fixed lease in the router, it is the network's DNS server
  networking.useDHCP = true;

  # Home services as containers (state in /var/lib/containers: kept, backed up)
  virtualisation = {
    containers.enable = true;
    podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true; # containers under podman-compose can talk to each other
    };
  };

  # Backups: add the restic-* keys to hosts/moon/secrets.yaml first (docs/cloud.md)
  backup = {
    enable = false;
    secretsFile = ./secrets.yaml;
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. Leave it at the first install's release.
  system.stateVersion = "24.11";
}
