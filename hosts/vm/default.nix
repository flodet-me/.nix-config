{
  config,
  inputs,
  pkgs,
  ...
}: {
  imports = [ inputs.impermanence.nixosModules.impermanence ];

  # 1. The Impermanence Core: Root is RAM
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "defaults" "size=2G" "mode=755" ];
  };

  # 2. Persistence: This will live on the VM's virtual drive
  # In a VM, /var/lib is usually where the 'real' disk is mounted
  environment.persistence."/persistent" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/etc/NetworkManager/system-connections"
    ];
    files = [ "/etc/machine-id" ];
  };


  fileSystems."/persistent" = {
    device = "/dev/vda"; # The emptyDiskImage above
    fsType = "ext4";
    autoFormat = true;
    neededForBoot = true;
  };


  # User setup
  users.users.testuser = {
    isNormalUser = true;
    password = "password"; # Don't do this on prod!
  };
}
