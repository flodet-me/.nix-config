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
      };
      vpn = {
        gateway = "vpn.fernuni-hagen.de";
        protocol = "anyconnect";
        service-type= "org.freedesktop.NetworkManager.openconnect";
      };
    };
  };
}