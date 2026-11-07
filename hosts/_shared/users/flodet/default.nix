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
      "podman"
      "vboxusers"
    ];
    # Deliberately simple: the login password only protects the screen lock and
    # sudo at the keyboard (sshd is off on the workstations, and servers have no
    # password at all, see server/default.nix). What protects the data is the
    # LUKS disk encryption (passphrase or YubiKey FIDO2, docs/installer.md).
    password = "123456789";
  };
}
