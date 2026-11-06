# Laptop/desktop upkeep: compressed swap in RAM, kill a runaway process before
# the desktop freezes, and a desktop notification when a disk reports trouble.
{
  zramSwap.enable = true;

  # Out of memory (a build, a VM, a browser tab): kills the biggest offender
  # and says so, instead of the whole session hanging.
  services.earlyoom = {
    enable = true;
    enableNotifications = true;
  };

  # SMART self-monitoring of all disks; warnings only as desktop notifications
  # (no mail setup needed).
  services.smartd = {
    enable = true;
    notifications.systembus-notify.enable = true;
  };
}
