# Ad-/tracker-blocking DNS resolver for the home network (blocky, native
# NixOS service instead of portal's docker container). Upstream queries are
# encrypted (DNS-over-TLS/HTTPS to Quad9, which also blocks malware domains;
# Mullvad's public DNS was shut down on 2026-11-02), nothing about clients is
# logged or forwarded. Point the router's DHCP DNS option at moon's address.
# Who may query it: ./firewall.nix.
{
  services.blocky = {
    enable = true;
    settings = {
      ports.dns = 53; # plain DNS for the LAN only (./firewall.nix); no DoH/DoT/HTTP API

      upstreams = {
        init.strategy = "fast"; # start answering before upstreams are verified
        groups.default = [
          "tcp-tls:dns.quad9.net:853"
          "https://dns.quad9.net/dns-query"
        ];
      };
      # Resolves the upstream names themselves, encrypted as well
      bootstrapDns = [
        {
          upstream = "https://dns.quad9.net/dns-query";
          ips = [
            "9.9.9.9"
            "149.112.112.112"
          ];
        }
      ];
      connectIPVersion = "dual";

      blocking = {
        denylists = {
          ads = [ "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" ];
          special = [
            "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews/hosts"
          ];
          # Telemetry ("phone home") of devices and OSes on the network: smart TVs,
          # Windows/Office, phones. Made to block tracking only, not functionality.
          telemetry =
            map
              (l: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/${l}-onlydomains.txt")
              [
                "native.winoffice"
                "native.samsung"
                "native.lgwebos"
                "native.amazon"
                "native.apple"
                "native.xiaomi"
                "native.tiktok.extended"
              ];
        };
        clientGroupsBlock.default = [
          "ads"
          "special"
          "telemetry"
        ];
        blockType = "zeroIp";
        loading = {
          refreshPeriod = "24h";
          # don't fail to start without internet (e.g. after a power cut);
          # lists are loaded in the background and retried
          strategy = "fast";
          downloads = {
            timeout = "60s";
            attempts = 5;
            cooldown = "10s";
          };
        };
      };

      # Local names under home.arpa (RFC 8375). Not bare names like "moon":
      # fqdnOnly answers those with NXDOMAIN before this mapping is read.
      customDNS = {
        customTTL = "1h";
        filterUnmappedTypes = true;
        mapping."moon.home.arpa" = "10.0.0.2,fd00::2"; # fixed lease / IPv6 token (default.nix)
      };

      caching = {
        minTime = "5m";
        prefetching = true;
      };

      # Privacy: no query log, don't pass client subnets to upstreams
      queryLog.type = "none";
      ecs.forward = false;
      fqdnOnly.enable = true;
      ede.enable = true;
      specialUseDomains.rfc6762-appendixG = true;
    };
  };

  # Port 53 is otherwise taken by systemd-resolved's stub; moon resolves via blocky
  services.resolved.settings.Resolve.DNSStubListener = false;
  networking.nameservers = [ "127.0.0.1" ];

  # Tighter sandbox than the NixOS module (same set as Caddy in server/web.nix)
  systemd.services.blocky.serviceConfig = {
    PrivateTmp = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    RestrictSUIDSGID = true;
    RemoveIPC = true;
    UMask = "0077";
  };
}
