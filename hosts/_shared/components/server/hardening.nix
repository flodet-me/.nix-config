# System hardening for servers: least privilege, minimal exposure, audit
# trail. Everything here was checked not to break the services in
# docs/cloud.md (VM test with PostgreSQL, Caddy, a DynamicUser app, restic).
# Measured with Lynis and `systemd-analyze security`, see docs/cloud.md.
{ lib, pkgs, ... }:
let
  # Rarely used protocols and filesystems with a history of kernel bugs,
  # plus USB storage / FireWire (nothing to plug in on a cloud VM).
  blockedModules = [
    "dccp"
    "sctp"
    "rds"
    "tipc"
    "cramfs"
    "freevxfs"
    "jffs2"
    "hfs"
    "hfsplus"
    "udf"
    "usb-storage"
    "firewire-core"
  ];
in
{
  # --- Kernel -----------------------------------------------------------------
  boot.kernel.sysctl = {
    # information leaks
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.perf_event_paranoid" = 3;
    # attack surface for local privilege escalation
    "kernel.unprivileged_bpf_disabled" = 1;
    "net.core.bpf_jit_harden" = 2;
    "kernel.yama.ptrace_scope" = 1;
    "vm.unprivileged_userfaultfd" = 0;
    "kernel.kexec_load_disabled" = 1; # no replacing the running kernel
    "kernel.sysrq" = 0;
    # files
    "fs.suid_dumpable" = 0;
    "fs.protected_fifos" = 2;
    "fs.protected_regular" = 2;
    # network: no routing tricks, no spoofing
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.secure_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv6.conf.all.accept_source_route" = 0;
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.tcp_rfc1337" = 1;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
  };

  # A blacklist only stops auto-loading; `install ... false` also blocks an
  # explicit modprobe.
  boot.blacklistedKernelModules = blockedModules;
  boot.extraModprobeConfig = lib.concatMapStrings (
    m: "install ${m} ${pkgs.coreutils}/bin/false\n"
  ) blockedModules;

  security.protectKernelImage = true;

  # No core dumps: they can contain secrets
  systemd.coredump.settings.Coredump = {
    Storage = "none";
    ProcessSizeMax = 0;
  };
  security.pam.loginLimits = [
    {
      domain = "*";
      item = "core";
      type = "hard";
      value = "0";
    }
  ];

  # --- Filesystems --------------------------------------------------------------
  boot.tmp.useTmpfs = true; # nosuid,nodev
  # No device files or setuid binaries where users and services write
  fileSystems."/home".options = [
    "nosuid"
    "nodev"
  ];
  fileSystems."/persist".options = [
    "nosuid"
    "nodev"
  ];
  boot.specialFileSystems."/dev/shm".options = [ "noexec" ];

  # --- Privileges ---------------------------------------------------------------
  # sudo-rs (memory-safe sudo), only executable by wheel at all
  security.sudo.enable = false;
  security.sudo-rs = {
    enable = true;
    execWheelOnly = true;
    wheelNeedsPassword = false; # see default.nix: the YubiKey is the gate
  };
  nix.settings.allowed-users = [ "@wheel" ];
  environment.defaultPackages = lib.mkForce [ ]; # no perl/rsync/strace by default

  # --- Network exposure ---------------------------------------------------------
  # resolved listens on 5353 (mDNS) and 5355 (LLMNR) by default: not needed
  services.resolved.settings.Resolve = {
    LLMNR = false;
    MulticastDNS = false;
  };

  # --- Audit trail ------------------------------------------------------------
  # Who ran what as root, and who touched the keys. Logs in /var/log/audit
  # (persisted). Read with: sudo ausearch -k root-cmds -i
  security.auditd.enable = true;
  security.audit = {
    enable = true;
    rules = [
      "-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -k root-cmds"
      "-w /persist/etc/ssh -p wa -k ssh-keys"
      "-w /persist/var/lib/sops-nix -p rwa -k sops-key"
      "-w /etc/sudoers -p wa -k sudoers"
    ];
  };
}
