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
    # TODO: flodet-password currently holds a plaintext password, but this
    # needs a hash (`mkpasswd -m yescrypt`). Replace the secret first, see
    # docs/secrets.md, or the user ends up without a usable password.
    # hashedPasswordFile = config.sops.secrets.flodet-password.path;
    password = "123456789";
  };
}
