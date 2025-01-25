{
  pkgs,
  config,
  ...
}: let
  ifTheyExist = groups: builtins.filter (group: builtins.hasAttr group config.users.groups) groups;;
in
{
  users.mutableUsers = false;
  users.users.flodet = {
    isNormalUser = true;
    description = "flodet";
    extraGroups = ifTheyExist [
      "networkmanager"
      "wheel"
      "docker"
      "vboxusers"
    ];
    shell = pkgs.zsh;
    packages = [pkgs.home-manager];
  };


  home-manager.users.gabriel = import ../../../../home/flodet/${config.networking.hostName}/default.nix;
}
