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
  systemd.oomd.enable = false; # GNOME enables it; earlyoom above does the same job

  # Hibernate (`systemctl hibernate`) to the encrypted btrfs swap file. systemd
  # records the swap file's location in an EFI variable when it hibernates and
  # the initrd reads it back, so no resume_offset kernel parameter is needed.
  # Used by suspend-then-hibernate: suspend first, hibernate after this delay.
  systemd.sleep.settings.Sleep.HibernateDelaySec = "2h";

  # /var/log and /var/lib/systemd (coredumps) survive reboots: cap what they keep.
  services.journald.settings.Journal = {
    SystemMaxUse = "500M";
    MaxRetentionSec = "3month";
  };
  systemd.coredump.settings.Coredump = {
    MaxUse = "1G";
    KeepFree = "5G";
  };

  # SMART self-monitoring of all disks; warnings only as desktop notifications
  # (no mail setup needed).
  services.smartd = {
    enable = true;
    notifications.systembus-notify.enable = true;
  };
}
