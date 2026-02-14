{ pkgs, config, ... }:

{
  environment.systemPackages = with pkgs; [
    #gaming
    lutris
    winetricks
    wineWow64Packages.stable
  ];

  # Install steam.
  programs.steam = {
    enable = true;
    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
    localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
  };
}
