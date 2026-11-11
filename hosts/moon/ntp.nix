# Time server for the home network (chrony; replaces systemd-timesyncd).
# moon syncs from public servers over NTS (authenticated NTP, so nobody on
# the way can shift its clock) and serves plain NTP to the LAN. Point the
# router's DHCP NTP option (42) at moon's address. Who may query it:
# ./firewall.nix (chrony itself answers everyone who gets through).
{
  services.chrony = {
    enable = true;
    enableNTS = true;
    # Four NTS servers from three operators, so one wrong clock is outvoted
    servers = [
      "time.cloudflare.com"
      "nts.netnod.se"
      "ptbtime1.ptb.de"
      "ptbtime2.ptb.de"
    ];
    extraConfig = ''
      allow
      # NTS checks certificates against the clock; if the clock is lost
      # (empty RTC battery) allow the first sync without that check
      nocerttimecheck 1
    '';
  };
}
