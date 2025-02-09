{ pkgs, config, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./networking.nix # generated at runtime by nixos-infect
    ../_shared/global.nix

  ];

  security.sudo.wheelNeedsPassword = false;
  nix.settings.trusted-users = [ "root" ];

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.hostName = "lunar";
  networking.domain = "";
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN9l0ZWdNgRv7wS68DquWySb+Zc5x9tJf3viat54Az0b''
  ];

  services.traefik = {
    enable = true;

    staticConfigOptions = {
      entryPoints = {
        web = {
          address = ":80";
          asDefault = true;
          http.redirections.entrypoint = {
            to = "websecure";
            scheme = "https";
          };
        };

        websecure = {
          address = ":443";
          asDefault = true;
          http.tls.certResolver = "letsencrypt";
        };
      };

      log = {
        level = "INFO";
        filePath = "${config.services.traefik.dataDir}/traefik.log";
        format = "json";
      };

      certificatesResolvers.letsencrypt.acme = {
        email = "postmaster@flodet.me";
        storage = "${config.services.traefik.dataDir}/acme.json";
        httpChallenge.entryPoint = "web";
      };

      api.dashboard = true;
      # Access the Traefik dashboard on <Traefik IP>:8080 of your server
      # api.insecure = true;
    };

    dynamicConfigOptions = {
      http.routers = { };
      http.services = { };
    };
  };

  virtualisation.docker.enable = true;

  system.stateVersion = "24.11";
}
