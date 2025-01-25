{
  pkgs,
  config,
  lib,
  ...
}:
let
  ifTheyExist = groups: builtins.filter (group: builtins.hasAttr group config.users.groups) groups;
in
{
  users.users.flodet = {
    isNormalUser = true;
    description = "flodet";
    shell = pkgs.zsh;
    extraGroups = ifTheyExist [
      "networkmanager"
      "audio"
      "git"
      "libvirtd"
      "lxd"
      "wireshark"
      "video"
      "wheel"
      "docker"
      "vboxusers"
    ];
  };
}
