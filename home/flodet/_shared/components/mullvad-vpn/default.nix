{ config, pkgs, ... }:

{

  sops = {
    age.keyFile = "~/.config/sops/age/keys.txt"; # must have no password!
    # It's also possible to use a ssh key, but only when it has no password:
    #age.sshKeyPaths = [ "/home/user/path-to-ssh-key" ];
    defaultSopsFile = ./secrets.yaml;
    defaultSymlinkPath = "/run/user/1000/secrets";
    defaultSecretsMountPoint = "/run/user/1000/secrets.d";

    secrets.mullvad-account-key = {
      # sopsFile = ./secrets.yml.enc; # optionally define per-secret files

      # %r gets replaced with a runtime directory, use %% to specify a '%'
      # sign. Runtime dir is $XDG_RUNTIME_DIR on linux and $(getconf
      # DARWIN_USER_TEMP_DIR) on darwin.
      path = "${config.sops.defaultSymlinkPath}/mullvad-account-key";
    };
  };

  # Install Mullvad VPN
  home.packages = with pkgs; [
    mullvad-vpn
  ];

  # Configure Mullvad VPN using a systemd service
  systemd.user.services.mullvad-configure = {
    Unit = {
      Description = "Configure Mullvad VPN settings";
      After = [ "network.target" "mullvad-daemon.service" ];
    };

    Service = {
      Type = "oneshot";
      Environment = [
        "MULLVAD_ACCOUNT_KEY=$(cat${config.sops.placeholder.mullvad-account-key})"
      ];
      ExecStart = ''
        ${pkgs.mullvad-vpn}/bin/mullvad account login YOUR_ACCOUNT_KEY
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
