{ config, ... }:
{
  services.mullvad-vpn = {
    enable = true;
    gui.enable = true;
  };

  sops.secrets.mullvad-account-key.sopsFile = ../users/flodet/user-secrets.yaml;

  # Keeps the daemon logged in with the account number from sops. The login
  # itself is stored in /etc/mullvad-vpn (persisted), so usually this only acts
  # on a fresh install, after a logout or when the device was revoked.
  systemd.services.mullvad-login = {
    description = "Log in to Mullvad with the account number from sops";
    # Logging in needs Mullvad's API, i.e. the network (Wi-Fi may come up late)
    after = [
      "mullvad-daemon.service"
      "network-online.target"
    ];
    wants = [
      "mullvad-daemon.service"
      "network-online.target"
    ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.services.mullvad-vpn.package ];
    unitConfig = {
      # Skip cleanly if sops couldn't decrypt (e.g. host key not registered yet)
      ConditionPathExists = config.sops.secrets.mullvad-account-key.path;
      StartLimitIntervalSec = 0; # keep retrying until the network is there
    };
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = 30;
    };
    # Account number via stdin so it never shows up in the process list.
    script = ''
      status=$(mullvad account get 2>&1 || true)
      case "$status" in
        *"has been revoked"*)
          echo "device was revoked, logging in again"
          mullvad account logout
          ;;
        *"Not logged in"*) ;;
        # daemon not ready yet: fail so Restart retries in 30s, not in 15 min
        *"Failed to connect"* | *"Could not connect"* | *"onnection refused"*)
          echo "$status" >&2
          exit 1
          ;;
        *)
          echo "already logged in"
          exit 0
          ;;
      esac
      mullvad account login < ${config.sops.secrets.mullvad-account-key.path}
      mullvad account get
    '';
  };

  # Re-check regularly (e.g. after a logout or a revoked device)
  systemd.timers.mullvad-login = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitInactiveSec = "15min";
    };
  };
}
