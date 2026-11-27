# Network map (nix-topology, docs/network.md): the hardware between the
# internet and the home LAN and the network services it runs. Only the fixed
# parts: devices that come and go over Wi-Fi (laptop, phones) are left out.
# NixOS hosts come from their configs; everything NixOS can't know (Vodafone,
# FRITZ! devices, cables) is declared here.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.lib.topology)
    mkInternet
    mkRouter
    mkDevice
    mkConnection
    ;
  moon = config.nixosConfigurations.moon.config;
  blocky = moon.services.blocky.settings;
  # Icons for services nix-topology has none for
  icon =
    name: body:
    pkgs.writeText "${name}.svg" ''
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#7aa2f7" stroke-width="2" stroke-linecap="round">${body}</svg>
    '';
  icons = {
    dns = icon "dns" ''<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18"/>'';
    ntp = icon "ntp" ''<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>'';
    dhcp = icon "dhcp" ''<rect x="4" y="4" width="16" height="16" rx="2"/><path d="M8 9h8M8 12h8M8 15h5"/>'';
  };
in
{
  networks.home = {
    name = "Home LAN";
    cidrv4 = "10.0.0.0/24";
    cidrv6 = "fd00::/64"; # Fritz!Box ULA prefix (hosts/moon/default.nix)
  };

  nodes = {
    internet = mkInternet {
      connections = [
        (mkConnection "vodafone" "wan")
        (mkConnection "quad9" "net")
        (mkConnection "nts" "net")
      ];
    };

    # Upstreams moon talks to, from its config
    quad9 = mkDevice "Quad9" {
      info = "Encrypted DNS upstream, blocks malware domains";
      deviceIcon = "devices.cloud-server";
      renderer.preferredType = "card";
      interfaces.net = { };
      services.dns = {
        name = "DNS over TLS / HTTPS";
        icon = icons.dns;
        info = lib.concatStringsSep " · " blocky.upstreams.groups.default;
      };
    };
    nts = mkDevice "NTS time servers" {
      info = "Authenticated time (NTS)";
      deviceIcon = "devices.cloud-server";
      renderer.preferredType = "card";
      interfaces.net = { };
      services.ntp = {
        name = "NTP with NTS";
        icon = icons.ntp;
        info = lib.concatStringsSep " · " moon.services.chrony.servers;
      };
    };

    vodafone = mkRouter "Vodafone router" {
      info = "ISP modem / router";
      interfaceGroups = [
        [ "wan" ]
        [ "lan" ]
      ];
      connections.lan = mkConnection "fritzbox" "wan";
    };

    fritzbox = mkRouter "FRITZ!Box 7530" {
      info = "Router, Wi-Fi mesh master";
      renderer.preferredType = "card";
      interfaceGroups = [
        [ "wan" ]
        [
          "lan"
          "wifi"
        ]
      ];
      connections.lan = mkConnection "moon" "enp2s0";
      connections.wifi = mkConnection "repeater" "wifi";
      interfaces.lan = {
        addresses = [ "10.0.0.1" ];
        network = "home";
      };
      interfaces.wifi.type = "wifi";
      services.dhcp = {
        name = "DHCP";
        icon = icons.dhcp;
        info = "hands out moon as DNS server";
      };
    };

    repeater = mkDevice "FRITZ!Repeater 1200 AX" {
      info = "Wi-Fi mesh repeater";
      interfaceGroups = [
        [
          "wifi"
          "lan"
        ]
      ];
      connections.lan = mkConnection "desktop" "enp42s0";
      interfaces.wifi = {
        type = "wifi";
        addresses = [ "10.0.0.20" ];
        network = "home";
      };
    };

    # The extractors find no interfaces: moon's network matches by type, not
    # name, and desktop uses NetworkManager.
    moon = {
      hardware.info = "Home server";
      interfaces.enp2s0 = {
        # fixed lease + IPv6 token, as blocky resolves moon.home.arpa
        addresses = lib.splitString "," blocky.customDNS.mapping."moon.home.arpa";
        addressFormatter = lib.concatStringsSep " · ";
        network = "home";
      };
      services.blocky = {
        info = "LAN DNS, blocks ads, trackers and telemetry";
        details.upstream.text = "Quad9";
      };
      services.chrony = {
        name = "chrony";
        icon = icons.ntp;
        info = "LAN NTP :123";
        details.upstream.text = "NTS servers";
      };
      services.fail2ban.hidden = true; # not a network service
    };

    desktop = {
      hardware.info = "Workstation";
      interfaces.enp42s0 = {
        addresses = [ "DHCP" ];
        network = "home";
      };
    };
  };
}
