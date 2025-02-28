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
  users.mutableUsers = false;
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
    # hashedPasswordFile = config.sops.secrets.flodet-password.path;
    password = "123456789";
  };

  sops = {
    age.keyFile = "/home/flodet/.config/sops/age/keys.txt";
    defaultSopsFile = ./secrets.yaml;
    secrets.flodet-password = {
      sopsFile = ./secrets.yaml;
      neededForUsers = true;
    };

  };

}
