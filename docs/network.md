# Network map

The home network's hardware and network services, drawn by
[nix-topology](https://github.com/oddlama/nix-topology) from `topology.nix`
and the NixOS configs of `moon` and `desktop`. Rendered locally:

```sh
nix build .#network-map
xdg-open result/main.svg      # devices, cables, Wi-Fi, services
xdg-open result/network.svg   # the Home LAN and who is in it
```

What it shows: Vodafone router → FRITZ!Box 7530 (10.0.0.1, DHCP) → moon by
cable (blocky DNS, chrony NTP), and → FRITZ!Repeater 1200 AX (10.0.0.20) over
Wi-Fi mesh → desktop by cable. Upstreams on the internet: Quad9 (blocky) and
the NTS time servers (chrony).

Where the facts come from:

| Fact | Source |
| --- | --- |
| moon's addresses, blocky's Quad9 upstreams | `hosts/moon/dns.nix` (read by `topology.nix`) |
| NTS servers | `hosts/moon/ntp.nix` (read by `topology.nix`) |
| Services found automatically (blocky, ssh, fail2ban, ...) | nix-topology's extractors; minor ones are hidden in `topology.nix` |
| Vodafone, FRITZ! devices, cables, interface names, Home LAN | written by hand in `topology.nix` |

Left out on purpose: laptop, phones and other devices that come and go over
Wi-Fi; VPNs and other client software; the `vps` template (no real address
yet). A new network service on moon or desktop shows up by itself if
nix-topology knows it; otherwise add it under `nodes.<host>.services` in
`topology.nix`.

The hosts themselves don't import nix-topology: `flake.nix` extends them with
its module only for the map, so their system builds stay unchanged.
