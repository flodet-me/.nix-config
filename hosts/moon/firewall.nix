# moon serves only the home network: DNS (./dns.nix), NTP (./ntp.nix) and
# SSH are accepted
# from private address ranges, never from the internet (e.g. over a public
# IPv6 address the router forwards).
{ config, lib, ... }:
let
  lan = {
    v4 = "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16";
    v6 = "fc00::/7, fe80::/10";
  };
in
{
  # The server base opens SSH to everyone; here the LAN rule below does it.
  services.openssh.openFirewall = lib.mkForce false;

  # extraInputRules only exist with nftables; without it the LAN rules below
  # would silently vanish and moon would stop answering.
  assertions = [
    {
      assertion = config.networking.nftables.enable;
      message = "hosts/moon/firewall.nix needs networking.nftables (firewall rules for the LAN).";
    }
  ];

  networking.firewall.extraInputRules = lib.mkAfter ''
    ip saddr { ${lan.v4} } tcp dport 22 accept
    ip6 saddr { ${lan.v6} } tcp dport 22 accept
    ip saddr { ${lan.v4} } meta l4proto { tcp, udp } th dport 53 accept
    ip6 saddr { ${lan.v6} } meta l4proto { tcp, udp } th dport 53 accept
    ip saddr { ${lan.v4} } udp dport 123 accept
    ip6 saddr { ${lan.v6} } udp dport 123 accept
  '';
}
