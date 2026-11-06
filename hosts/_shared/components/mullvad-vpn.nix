{ config, ... }:
{
  services.mullvad-vpn = {
    enable = true;
    gui.enable = true;
  };

  sops.secrets.mullvad-account-key.sopsFile = ../users/flodet/user-secrets.yaml;

  # Log in once from the sops secret. The login itself is kept in
  # /etc/mullvad-vpn (persisted), so this is a no-op on normal boots.
  systemd.services.mullvad-login = {
    description = "Log in to Mullvad with the account number from sops";
    after = [ "mullvad-daemon.service" ];
    wants = [ "mullvad-daemon.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.services.mullvad-vpn.package ];
    unitConfig = {
      # Skip cleanly if sops couldn't decrypt (e.g. host key not registered yet)
      ConditionPathExists = config.sops.secrets.mullvad-account-key.path;
      StartLimitIntervalSec = 120;
      StartLimitBurst = 5;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # The daemon's socket may not be ready right after it starts.
      Restart = "on-failure";
      RestartSec = 5;
    };
    # Account number via stdin so it never shows up in the process list.
    script = ''
      if mullvad account get | grep -q "Not logged in"; then
        mullvad account login < ${config.sops.secrets.mullvad-account-key.path}
      fi
    '';
  };
}
