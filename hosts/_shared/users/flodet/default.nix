# The login user on the workstations. Servers define their own, see
# components/server/default.nix.
{
  pkgs,
  config,
  ...
}:
let
  ifTheyExist = groups: builtins.filter (group: builtins.hasAttr group config.users.groups) groups;
in
{
  users.mutableUsers = false;
  users.users.${config.host.user} = {
    isNormalUser = true;
    description = config.host.user;
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
    # LUKS disk encryption (passphrase at boot, docs/installer.md).
    password = "123456789";
  };
}
