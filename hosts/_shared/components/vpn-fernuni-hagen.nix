{
  pkgs,
  ...
}:
{
  environment.systemPackages = with pkgs; [
    openconnect
  ];

  networking.networkmanager.ensureProfiles.profiles = {
    uni = {
      connection = {
        id = "fernuni-hagen";
        type = "vpn";
        autoconnect = "false";
      };
      vpn = {
        authtype= "password";
        gateway = "vpn.fernuni-hagen.de";
        protocol = "anyconnect";
        service-type = "org.freedesktop.NetworkManager.openconnect";
      };
      ipv4 = {
        method = "auto";
      };
      ipv6 = {
        addr-gen-mode= "default";
        method = "auto";
      };
    };
  };
}
