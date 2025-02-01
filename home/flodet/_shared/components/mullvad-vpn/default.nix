{ config, pkgs, ... }:

{

  sops.secrets.mullvad-account-key.path = "${config.sops.defaultSymlinkPath}/mullvad-account-key";

  # Install Mullvad VPN
  home.packages = with pkgs; [
    mullvad-vpn
  ];

  # FIXME: Impure assignment of secret
  # Configure Mullvad VPN using a systemd service
  systemd.user.services.mullvad-configure = {
    Unit = {
      Description = "Configure Mullvad VPN settings";
      After = [
        "network.target"
        "mullvad-daemon.service"
        "sops-nix.service"
      ];
    };

    Service = {
      Type = "oneshot";
      Environment = [
        "MULLVAD_ACCOUNT_KEY=${builtins.readFile config.sops.secrets.mullvad-account-key.path}"
      ];
      ExecStart = ''
        ${pkgs.mullvad-vpn}/bin/mullvad account login $MULLVAD_ACCOUNT_KEY
      '';
      ExecStop = ''
        ${pkgs.mullvad-vpn}/bin/mullvad account logout
      '';
      RemainAfterExit = true;
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
