# systemd-boot on a UEFI machine, keeping 10 generations to roll back to.
{
  boot.loader = {
    systemd-boot = {
      enable = true;
      configurationLimit = 10;
      # No editing of the kernel command line at the boot menu: anyone at the
      # keyboard could add `init=/bin/sh` there. Generations can still be chosen
      # (hold a key at boot, the menu timeout is 0).
      editor = false;
    };
    efi.canTouchEfiVariables = true;
  };
}
