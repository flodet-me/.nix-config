# Public web apps behind Caddy with automatic HTTPS (Let's Encrypt):
#
#   server.web.email = "admin@example.org";
#   server.web.sites."app.example.org".port = 8080;          # reverse proxy to 127.0.0.1:8080
#   server.web.sites."files.example.org".root = "/var/lib/www";  # static files
#
# Ports 80/443 open only when there is at least one site. Certificates live
# in /var/lib/caddy (persisted and backed up on servers).
{
  config,
  lib,
  ...
}:
let
  cfg = config.server.web;
  site = lib.types.submodule {
    options = {
      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "Local port of the app (bound to 127.0.0.1) to reverse proxy to.";
      };
      root = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Directory to serve static files from.";
      };
      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Extra Caddyfile directives for this site (e.g. basic_auth).";
      };
    };
  };
in
{
  options.server.web = {
    email = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Contact address for Let's Encrypt.";
    };
    sites = lib.mkOption {
      type = lib.types.attrsOf site;
      default = { };
      description = "Public sites by domain name.";
    };
  };

  config = lib.mkIf (cfg.sites != { }) {
    assertions = lib.mapAttrsToList (domain: s: {
      assertion = (s.port == null) != (s.root == null);
      message = "server.web.sites.\"${domain}\": set exactly one of port or root";
    }) cfg.sites;

    services.caddy = {
      enable = true;
      inherit (cfg) email;
      virtualHosts = lib.mapAttrs (_: s: {
        extraConfig = lib.concatStringsSep "\n" (
          [
            "encode zstd gzip"
            ''
              header {
                Strict-Transport-Security "max-age=31536000; includeSubDomains"
                X-Content-Type-Options nosniff
                Referrer-Policy strict-origin-when-cross-origin
                -Server
              }
            ''
          ]
          ++ lib.optional (s.port != null) "reverse_proxy 127.0.0.1:${toString s.port}"
          ++ lib.optional (s.root != null) "root * ${s.root}\nfile_server"
          ++ [ s.extraConfig ]
        );
      }) cfg.sites;
    };

    # Caddy faces the internet: tighten its sandbox beyond the NixOS module
    systemd.services.caddy.serviceConfig = {
      ProtectSystem = "strict";
      ReadWritePaths = [
        "/var/lib/caddy"
        "/var/log/caddy"
      ];
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RemoveIPC = true;
      PrivateUsers = false; # needs CAP_NET_BIND_SERVICE in the host namespace
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "~@resources"
      ];
      UMask = "0077";
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
    networking.firewall.allowedUDPPorts = [ 443 ]; # HTTP/3
  };
}
