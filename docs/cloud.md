# Cloud servers

Template: `hosts/vps/` (Hetzner Cloud); `hosts/moon/` uses the same base at home. Base module:
`hosts/_shared/components/server/`. Workstation side:
`hosts/_shared/components/server-access.nix`.

## Design decisions

**Filesystem: btrfs + impermanence** (same as the workstations).
The root is replaced on every boot; only `/nix`, `/home`, `/persist` and the
paths declared in `impermanence/default.nix` survive. On a server this means:

- no configuration drift: anything not declared is gone after a reboot,
- backups are small and complete: `/persist` + `/home` *is* the state,
- consistent backups of running services via read-only btrfs snapshots,
- on servers all of `/var/lib` is kept, so new services need no extra config,
- `fs-diff` shows state a new service writes that isn't persisted yet.

ext4 works too but has no snapshots; ZFS is overkill for one virtual disk.

**Disk encryption: off by default.** The provider controls the hypervisor
(and can read RAM), so LUKS mostly protects against discarded disks, while
every reboot would need a manual unlock. What matters is that data *leaving*
the server is encrypted: backups are encrypted client-side by restic.
If you want LUKS anyway: `encrypt = true` in the host's disko import, plus
`boot.initrd.network.ssh` to unlock remotely after reboots.
moon (at home) is unencrypted on purpose: it has to come back after a power cut
without someone typing a passphrase, and none of the machines has a TPM that
could unlock a disk by itself. It holds nothing secret (it has no secrets
yet, and the config is in git); a stolen disk would expose its age key and SSH
host key, which you would replace by reinstalling.

**Access: one hardware key, no passwords.**

- Login only as `flodet`, only with the YubiKey's SSH key
  (`keys/flodet-ssh.pub`, the gpg auth subkey). No root login, no passwords
  anywhere (`hashedPassword = "!"`).
- `sudo` needs no password: the only way in is already the hardware key.
- Turn on touch-to-use so malware on a workstation can't use the key
  silently: `ykman openpgp keys set-touch aut on` (once, on the YubiKey).
- The server's SSH host key is generated locally before installing and pinned
  on the workstations (`programs.ssh.knownHosts`), so there is never a
  trust-on-first-use moment.
- Agent forwarding is disabled on the server side.

**Secrets:** each server has its own `hosts/<host>/secrets.yaml`, readable only
by that server (and the YubiKey). Servers can't read workstation secrets.

**Updates are pushed, not pulled:** no `autoUpgrade`; you deploy from a
workstation, after building locally (and CI building it too).

**Hardening:** see "Security" below (`server/hardening.nix`).

## New server

1. Create the VM (Hetzner: any x86 image, e.g. Ubuntu; add `keys/flodet-ssh.pub`
   as SSH key so you can log in as root once). Note IPv4 and the IPv6 subnet.
2. Copy `hosts/vps` to `hosts/<name>`, adjust hostname, IPv6, disk, services,
   and set `stateVersion` to the current release (the template keeps the one
   it was written with). Add it to `flake.nix` and to `servers` in
   `server-access.nix`, then `git add hosts/<name>`: flakes ignore files git
   does not know, which shows up as a confusing "path does not exist" error.
3. With the YubiKey plugged in:
   ```sh
   provision-server <name> root@<ipv4>
   ```
   It creates the server's sops key and SSH host key locally, registers the
   key (own secrets rule), pins the host key, then installs with
   nixos-anywhere (wipes the disk) and copies the keys over. Private keys
   never touch the repo.
4. Commit `keys/hosts/<name>.age`, `.sops.yaml` and `hosts/<name>/`, rebuild your workstation
   (`sudo nixos-rebuild switch --flake .#desktop`), then `ssh <name>`.

## Day to day

```sh
# deploy (builds locally, copies, activates)
nixos-rebuild switch --flake .#<name> --target-host <name> --sudo
# try without making it the boot default
nixos-rebuild test --flake .#<name> --target-host <name> --sudo
# server secrets
sops hosts/<name>/secrets.yaml
# what a new service writes outside of persisted paths
ssh <name> fs-diff
```

Rollback: `nixos-rebuild switch --rollback --target-host <name> --sudo`, or pick
an older generation in the boot menu (Hetzner console).

## Services

Adding a service is three steps, everything else is automatic:

```nix
# 1. the NixOS module, listening on localhost only
services.uptime-kuma = {
  enable = true;
  settings.HOST = "127.0.0.1";
  settings.PORT = "3001";
};
# 2. publish it: HTTPS via Caddy + Let's Encrypt, ports 80/443 opened
server.web = {
  email = "admin@example.org";
  sites."status.example.org".port = 3001;   # or .root = "/var/lib/www" for static files
};
```

3. Deploy (`nixos-rebuild switch --flake .#<name> --target-host <name> --sudo`).

What happens automatically:

- **State is kept and backed up:** servers persist all of `/var/lib`
  (`impermanence.persistVarLib`), where NixOS services keep their state,
  including `DynamicUser` services (`/var/lib/private`). Everything outside
  (`/etc`, `/root`, `/srv`, `/var/cache`, ...) is still wiped on reboot;
  `fs-diff` shows if a service writes there.
- **Databases:** with `services.postgresql` enabled, all databases are dumped
  daily at 01:15 to `/var/backup/postgresql` (kept and backed up).
- **Web:** HSTS and other security headers, compression, HTTP/3; certificates
  in `/var/lib/caddy`. Site-specific Caddy directives go in
  `sites.<domain>.extraConfig` (e.g. `basic_auth` for admin UIs).

Further rules:

- Prefer NixOS service modules over containers (systemd sandboxing, typed
  config). For containers use podman via `virtualisation.oci-containers`,
  volumes under `/var/lib/<name>`.
- Secrets: `sops.secrets.<name>.sopsFile = ./secrets.yaml;`, pass the path
  (`config.sops.secrets.<name>.path`) to the service, never the value.
- Ports that aren't web: open them explicitly
  (`networking.firewall.allowedTCPPorts`), only if they must be public.

Tested in a VM (2026-11-06): PostgreSQL, a `DynamicUser` app and a
`server.web` site survive a reboot and are in the backup; restore works.

## Backups

restic (`server/backup.nix`): daily at 02:00, deduplicated, encrypted before
upload. It snapshots `/persist` and `/home` read-only (consistent while
services run), backs up the snapshot, prunes (7 daily, 5 weekly, 12 monthly)
and verifies 5% of the data each run. A backup that comes out empty fails
the unit instead of being reported as success.

The backup contains the server's sops key (`/var/lib/sops-nix/key.txt`), so a
restored server can decrypt its secrets again. Keep the restic password
safe: it protects that key too.

Setup:

1. A target: Hetzner Storage Box (SFTP, port 23, cheap, same provider: fine
   for a start) or an S3-compatible bucket at a *different* provider (better,
   the 3-2-1 rule: survive losing the whole account).
2. `sops hosts/<name>/secrets.yaml`:
   ```yaml
   restic-repository: sftp://uXXXXXX@uXXXXXX.your-storagebox.de:23//backups/<name>
   restic-password: <long random string, ALSO in your password manager>
   restic-ssh-key: |             # Storage Box only (backup.sftpKey = true)
     -----BEGIN OPENSSH PRIVATE KEY-----
     ...
   restic-env: |                 # S3/B2 only (backup.withEnvironment = true)
     AWS_ACCESS_KEY_ID=...
     AWS_SECRET_ACCESS_KEY=...
   ntfy-url: https://ntfy.sh/<long-random-topic>   # backup.notifyOnFailure = true
   ```
   For the Storage Box, create the key with `ssh-keygen -t ed25519 -N ""` and
   add its public half in the Storage Box settings; pin the box's host key:
   `backup.sshKnownHosts = "<output of ssh-keyscan -p 23 uXXXXXX.your-storagebox.de>";`
3. `backup.enable = true;`, deploy, run it once and test a restore:
   ```sh
   ssh <name> sudo systemctl start restic-backups-main
   ssh <name> sudo restic-main snapshots
   ssh <name> sudo restic-main restore latest --target /tmp/restore \
     --include /.snapshots/backup/persist/var/lib/<service>
   ```
4. Alerts: with `notifyOnFailure`, a failed backup, check or database dump
   sends a push notification (subscribe to the topic in the ntfy app). The
   topic name is the only secret, so make it long and random.

## Security

Principles: nothing reachable that isn't needed, every component with the
least rights that work, an audit trail, and no secret in plaintext anywhere
but RAM. Measured on the VM test server: Lynis hardening index 72 → 79,
Caddy's systemd exposure 7.8 ("exposed") → 1.4 ("ok").

| Area | What (`server/default.nix`, `server/hardening.nix`, `server/web.nix`) |
| --- | --- |
| Exposure | only 22 (+ 80/443 with sites) open; mDNS/LLMNR off; apps bind to 127.0.0.1 |
| Login | YubiKey SSH key only, only `flodet`, no passwords at all, no root login |
| SSH | post-quantum KEX (mlkem768x25519), AEAD ciphers, local port forwarding only (no `-R`, tunnels, agent/X11/socket forwarding), 3 tries, idle timeout |
| Privileges | `flodet` only in `wheel`; sudo-rs (memory-safe), executable only by wheel; Nix daemon only for wheel |
| Services | Caddy sandboxed (read-only system, only `CAP_NET_BIND_SERVICE`, syscall filter, no W^X memory); NixOS modules bring their own sandboxing |
| Kernel | sysctls against info leaks and local privilege escalation (kexec, BPF, userfaultfd, ptrace, perf), no redirects/source routing; risky protocols and filesystems blocked even for explicit `modprobe` |
| Filesystems | `/home`, `/persist` nosuid,nodev; `/dev/shm` noexec; `/tmp` tmpfs; root wiped on boot |
| Secrets | sops, decrypted to RAM only, per-server file; no core dumps |
| Audit | auditd: every command run as root by a user (`sudo ausearch -k root-cmds -i`), access to SSH host key and sops key |
| Updates | deployed from the workstation, built locally and in CI |

Not done on purpose (would break things or don't apply): hardened kernel
(breaks some services), `lockKernelModules` (nftables loads modules on
demand), password policies (there are no passwords), GRUB password (the
provider controls the console anyway).

Hardening a service of your own (systemd unit): start from

```nix
systemd.services.myapp.serviceConfig = {
  DynamicUser = true;              # throwaway user, state in /var/lib/private/myapp
  StateDirectory = "myapp";
  ProtectSystem = "strict";
  ProtectHome = true;
  PrivateTmp = true;
  PrivateDevices = true;
  NoNewPrivileges = true;
  CapabilityBoundingSet = "";
  RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
  SystemCallFilter = [ "@system-service" "~@privileged" ];
  MemoryDenyWriteExecute = true;
};
```

and check with `systemd-analyze security myapp` (aim for < 3).

**Your side of it:**

- YubiKey: `ykman openpgp keys set-touch aut on` (every SSH login needs a
  touch, so malware on a workstation can't use the key silently).
- Deploy updates regularly (`nix flake update`, build, deploy): this is
  where security fixes come from.
- Break-glass: there is no console password. If SSH is broken, boot the
  provider's rescue system, mount the disk and fix or roll back (older
  generations in the boot menu also work from the provider's console).

## Better than SSH on the internet (optional)

Put management on a private network: Tailscale/Headscale or plain WireGuard
on workstations and servers, then remove `openFirewall` from sshd and allow SSH
only on that interface (`networking.firewall.interfaces.<if>.allowedTCPPorts`).
Keep the Hetzner web console as the break-glass access.

## Checklist for a new service

- [ ] listens on 127.0.0.1, published via `server.web` (or port opened only if it must be public)
- [ ] state under `/var/lib` (automatic for NixOS modules; check `ssh <name> fs-diff` after a day)
- [ ] secrets via sops file paths
- [ ] restore tested once
