# flodet's secrets on the workstations (desktop, laptop). Servers don't import
# this and are not recipients of these files (see .sops.yaml).
{
  sops.secrets = {
    flodet-password = {
      sopsFile = ./secrets.yaml;
      neededForUsers = true;
    };

    # Read by the user session (hyprland); decrypted to /run/secrets/<name>.
    home-location = {
      sopsFile = ./user-secrets.yaml;
      owner = "flodet";
    };
    weather-api-key = {
      sopsFile = ./user-secrets.yaml;
      owner = "flodet";
    };
  };
}
