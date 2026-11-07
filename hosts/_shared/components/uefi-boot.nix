# systemd-boot on a UEFI machine, keeping 10 generations to roll back to.
{
  boot.loader = {
    systemd-boot = {
      enable = true;
      configurationLimit = 10;
    };
    efi.canTouchEfiVariables = true;
  };
}
