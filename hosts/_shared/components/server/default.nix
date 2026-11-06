# Base for (cloud) servers: SSH with the YubiKey only, minimal attack
# surface, impermanent btrfs root, backups via ./backup.nix.
# Guidance and the install/deploy workflow: docs/cloud.md
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ../impermanence
    ./backup.nix
    ./hardening.nix
    ./web.nix
  ];

  # Every service's state (/var/lib) survives reboots and is backed up,
  # without having to list it. The rest of the root is still wiped.
  impermanence.persistVarLib = true;

  host.role = "server"; # own secrets file only (sops-sync)

  # --- Access -------------------------------------------------------------
  # Only flodet, only with the YubiKey's SSH key (gpg auth subkey). No
  # passwords anywhere, no root login. sudo needs no password: the only way
  # in is already the hardware key (enable touch-to-use, docs/cloud.md).
  users.users.flodet = {
    password = lib.mkForce null;
    hashedPassword = "!";
    extraGroups = lib.mkForce [ "wheel" ]; # nothing a server doesn't need
    openssh.authorizedKeys.keyFiles = [ ../../../../keys/flodet-ssh.pub ];
  };
  users.users.root.hashedPassword = "!";

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AuthenticationMethods = "publickey";
      AllowUsers = [ "flodet" ];
      X11Forwarding = false;
      AllowAgentForwarding = false;
      AllowStreamLocalForwarding = false;
      # `ssh -L` to reach internal admin UIs; no remote/reverse forwards
      AllowTcpForwarding = "local";
      PermitTunnel = "no";
      MaxAuthTries = 3;
      MaxSessions = 4;
      LoginGraceTime = 20;
      ClientAliveInterval = 300;
      ClientAliveCountMax = 2;
      # Modern algorithms only (post-quantum hybrid KEX first)
      KexAlgorithms = [
        "mlkem768x25519-sha256"
        "sntrup761x25519-sha512@openssh.com"
        "curve25519-sha256"
        "curve25519-sha256@libssh.org"
      ];
      Ciphers = [
        "chacha20-poly1305@openssh.com"
        "aes256-gcm@openssh.com"
        "aes128-gcm@openssh.com"
      ];
      Macs = [
        "hmac-sha2-512-etm@openssh.com"
        "hmac-sha2-256-etm@openssh.com"
      ];
    };
  };

  # Slows down scanners; with key-only auth it is mainly log hygiene.
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime-increment.enable = true;
  };

  # --- Network ------------------------------------------------------------
  networking.firewall = {
    enable = true;
    allowPing = true;
    logRefusedConnections = false; # noise
  };
  networking.nftables.enable = true;
  networking.useNetworkd = true;

  # --- Operations -----------------------------------------------------------
  services.journald.settings.Journal = {
    SystemMaxUse = "1G";
    MaxRetentionSec = "3month";
  };
  # No desktop bits
  documentation.enable = false;
  programs.nix-ld.enable = lib.mkForce false;
  programs.command-not-found.enable = false;
  fonts.fontconfig.enable = false;
  xdg.icons.enable = false;
  xdg.mime.enable = false;
  xdg.sounds.enable = false;
  nix.channel.enable = false; # flakes only
  time.timeZone = lib.mkForce "UTC";

  # Small admin toolset on purpose: no workstation extras (media libraries,
  # nmap, strace, ...) that only add CVEs and help an intruder.
  environment.systemPackages = with pkgs; [
    btop
    curl
    git
    jq
    lsof
    restic
    ripgrep
  ];

  # Updates are deployed from a workstation (docs/cloud.md), not pulled.
  system.autoUpgrade.enable = false;

  assertions = [
    {
      assertion = config.services.openssh.settings.PasswordAuthentication == false;
      message = "servers must not allow SSH password logins";
    }
  ];
}
