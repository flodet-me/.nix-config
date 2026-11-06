# Example cloud server (Hetzner Cloud, x86). Copy this directory for each new
# server, adjust the values marked TODO, and add it to flake.nix and
# hosts/_shared/components/server-access.nix. Workflow: docs/cloud.md
{
  inputs,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../_shared/global.nix
    ../_shared/components/server
    # Hetzner Cloud VMs boot via legacy BIOS; the ESP is kept so the same
    # disk also boots on UEFI (e.g. Hetzner's arm CAX or other providers).
    (import ../_shared/components/impermanence/disko.nix {
      device = "/dev/sda";
      swapSize = "4G";
      encrypt = false; # docs/cloud.md: "Disk encryption"
      biosBoot = true;
    })
  ];

  networking.hostName = "vps";
  nixpkgs.hostPlatform = "x86_64-linux"; # aarch64-linux for Hetzner CAX

  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  boot.initrd.availableKernelModules = [
    "ahci"
    "xhci_pci"
    "virtio_pci"
    "virtio_scsi"
    "sd_mod"
    "sr_mod"
  ];

  # Hetzner Cloud: IPv4 via DHCP, IPv6 is static (address from the console).
  systemd.network.networks."10-uplink" = {
    matchConfig.Name = "en*";
    networkConfig.DHCP = "ipv4";
    # TODO: the server's IPv6 subnet from the Hetzner console, then uncomment
    # address = [ "2a01:4f8:xxxx:xxxx::1/64" ];
    routes = [ { Gateway = "fe80::1"; } ];
  };

  # Services: enable the NixOS module, bind it to localhost, publish it with
  # server.web. Its state in /var/lib is kept and backed up automatically,
  # databases are dumped before each backup. Example (docs/cloud.md):
  #
  # services.uptime-kuma = {
  #   enable = true;
  #   settings.HOST = "127.0.0.1";
  #   settings.PORT = "3001";
  # };
  # server.web = {
  #   email = "admin@example.org";
  #   sites."status.example.org".port = 3001;
  # };

  # Secrets: `sops hosts/vps/secrets.yaml` (after provision-server registered
  # the host), then declare each one with its file, e.g.
  # sops.secrets.app-token.sopsFile = ./secrets.yaml;

  # Backups: add the restic-* keys to hosts/vps/secrets.yaml first
  # (see server/backup.nix and docs/cloud.md)
  backup = {
    enable = false;
    secretsFile = ./secrets.yaml;
    # sftpKey = true;          # Storage Box: restic-ssh-key in the secrets
    # notifyOnFailure = true;  # ntfy-url in the secrets
    # sshKnownHosts = "[uXXXXXX.your-storagebox.de]:23 ssh-ed25519 AAAA...";
  };

  system.stateVersion = "26.05";
}
