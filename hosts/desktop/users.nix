{
  pkgs,
  ...
}:
{
  users.users.flodet = {
    isNormalUser = true;
    description = "flodet";
    extraGroups = [
      "networkmanager"
      "wheel"
      "docker"
      "vboxusers"
    ];
    shell = pkgs.zsh;
  };
}
