# Encrypted, deduplicated backups of everything that survives a reboot
# (/persist and /home), with restic. Off until the repository secrets exist:
#
#   hosts/<host>/secrets.yaml   (sops, readable only by that host)
#     restic-repository: sftp:u123456@u123456.your-storagebox.de:/backups/<host>
#     restic-password:   <long random string, ALSO keep it in your password manager>
#     restic-env:        optional KEY=value lines (e.g. AWS_ACCESS_KEY_ID=... for S3/B2)
#     ntfy-url:          optional, https://ntfy.sh/<long-random-topic> for failure alerts
#     restic-ssh-key:    optional, private SSH key for an SFTP repository (Storage Box)
#
# then `backup.enable = true;` in the host. See docs/cloud.md.
#
# Databases are dumped automatically before the backup (PostgreSQL: all
# databases to /var/backup/postgresql), on top of the crash-consistent snapshot.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.backup;
  snapshot = "/.snapshots/backup";
in
{
  options.backup = {
    enable = lib.mkEnableOption "restic backups of /persist and /home";
    secretsFile = lib.mkOption {
      type = lib.types.path;
      description = "sops file with restic-repository, restic-password (and optionally restic-env).";
    };
    withEnvironment = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether secretsFile has restic-env (credentials for S3/B2/...).";
    };
    exclude = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "persist/var/log"
        "persist/var/lib/systemd/coredump"
        "home/*/.cache"
      ];
      description = "Paths relative to the snapshot root to skip.";
    };
    sftpKey = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether secretsFile has restic-ssh-key (SSH key for an SFTP repository).";
    };
    notifyOnFailure = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Push a notification (ntfy-url in secretsFile) when a backup, check or dump fails.";
    };
    sshKnownHosts = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "known_hosts line(s) of an SFTP repository (pinned, no TOFU).";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets = {
      restic-repository.sopsFile = cfg.secretsFile;
      restic-password.sopsFile = cfg.secretsFile;
    }
    // lib.optionalAttrs cfg.withEnvironment { restic-env.sopsFile = cfg.secretsFile; }
    // lib.optionalAttrs cfg.sftpKey { restic-ssh-key.sopsFile = cfg.secretsFile; }
    // lib.optionalAttrs cfg.notifyOnFailure { ntfy-url.sopsFile = cfg.secretsFile; };

    # Logical dumps, finished before the backup runs (02:00)
    services.postgresqlBackup = lib.mkIf config.services.postgresql.enable {
      enable = true;
      backupAll = true;
      location = "/var/backup/postgresql";
      compression = "zstd";
      startAt = "*-*-* 01:15:00";
    };
    services.restic.backups.main = {
      initialize = true;
      repositoryFile = config.sops.secrets.restic-repository.path;
      passwordFile = config.sops.secrets.restic-password.path;
      environmentFile = lib.mkIf cfg.withEnvironment config.sops.secrets.restic-env.path;

      # A read-only btrfs snapshot gives a consistent view while services run
      # (crash-consistent, which databases like PostgreSQL handle).
      backupPrepareCommand = ''
        ${pkgs.btrfs-progs}/bin/btrfs subvolume delete ${snapshot}/persist ${snapshot}/home 2>/dev/null || true
        mkdir -p ${snapshot}
        ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot -r /persist ${snapshot}/persist
        ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot -r /home ${snapshot}/home
      '';
      backupCleanupCommand = ''
        ${pkgs.btrfs-progs}/bin/btrfs subvolume delete ${snapshot}/persist ${snapshot}/home
      '';
      paths = [ snapshot ];
      exclude = map (p: "${snapshot}/${p}") cfg.exclude;
      # No --one-file-system: the snapshots are separate btrfs subvolumes, restic
      # would skip their contents.
      extraBackupArgs = [ "--exclude-caches" ];
      extraOptions = lib.optional cfg.sftpKey "sftp.args='-i ${config.sops.secrets.restic-ssh-key.path} -o IdentitiesOnly=yes'";

      timerConfig = {
        OnCalendar = "*-*-* 02:00:00";
        RandomizedDelaySec = "30m";
        Persistent = true;
      };
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 5"
        "--keep-monthly 12"
      ];
      # Verify a random 5% of the data on each run
      runCheck = true;
      checkOpts = [ "--read-data-subset=5%" ];
    };

    environment.etc."ssh/ssh_known_hosts_backup" = lib.mkIf (cfg.sshKnownHosts != "") {
      text = cfg.sshKnownHosts;
    };
    programs.ssh.extraConfig = lib.mkIf (cfg.sshKnownHosts != "") ''
      GlobalKnownHostsFile /etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts_backup
    '';

    # restic's cache (CacheDirectory of the service) and the dumps
    environment.persistence."/persist".directories = [
      "/var/cache/restic-backups-main"
      "/var/backup"
    ];

    systemd.services = lib.mkMerge [
      {
        # Refuse to call an empty snapshot a backup (fails the unit -> alert)
        restic-backups-main.serviceConfig.ExecStartPost = [
          (pkgs.writeShellScript "restic-verify-not-empty" ''
            # --no-lock and grep -c (reads everything): an early-exiting grep -q
            # would kill restic and leave a stale lock in the repository.
            files=$(${pkgs.restic}/bin/restic --no-lock ls latest | ${pkgs.gnugrep}/bin/grep -c "^${snapshot}/persist/var/" || true)
            if [ "$files" -eq 0 ]; then
              echo "latest snapshot contains nothing under /persist/var" >&2
              exit 1
            fi
          '')
        ];
      }

      (lib.mkIf config.services.postgresql.enable {
        # The dump directory may not exist yet under a freshly bind-mounted /var/backup
        postgresqlBackup.serviceConfig.ExecStartPre = [
          "+${pkgs.coreutils}/bin/install -d -m 700 -o postgres /var/backup/postgresql"
        ];
      })

      (lib.mkIf cfg.notifyOnFailure {
        "notify-failure@" = {
          description = "Push notification about failed %i";
          scriptArgs = "%i";
          serviceConfig = {
            Type = "oneshot";
            DynamicUser = true;
            LoadCredential = "url:${config.sops.secrets.ntfy-url.path}";
          };
          script = ''
            ${pkgs.curl}/bin/curl -fsS --retry 3 \
              -H "Title: ${config.networking.hostName}: $1 failed" -H "Priority: high" -H "Tags: warning" \
              -d "Check: journalctl -u $1" "$(cat "$CREDENTIALS_DIRECTORY/url")"
          '';
        };
        restic-backups-main.onFailure = [ "notify-failure@%n.service" ];
        postgresqlBackup.onFailure = lib.mkIf config.services.postgresql.enable [
          "notify-failure@%n.service"
        ];
      })
    ];
  };
}
