# Laptop/desktop upkeep: compressed swap in RAM, kill a runaway process before
# the desktop freezes, and a desktop notification when a disk reports trouble.
{
  # zram (priority 5) fills before the disk swap file (priority -2), which stays
  # for suspend-then-hibernate.
  zramSwap.enable = true;

  # Tuned for swap on zram (ArchWiki "Zram", section "Optimizing swap on zram"):
  # swapping to compressed RAM is cheaper than dropping page cache, and
  # readahead of neighbouring pages only pays off on disks.
  boot.kernel.sysctl = {
    "vm.swappiness" = 180;
    "vm.page-cluster" = 0;
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
  };

  # Out of memory (a build, a VM, a browser tab): kills the biggest offender
  # and says so, instead of the whole session hanging.
  services.earlyoom = {
    enable = true;
    enableNotifications = true;
    # Act once zram is full, before the disk swap file thrashes. zram is 50% of
    # RAM and the swap file is about the RAM size (desktop 32G of 31.3 GiB RAM,
    # laptop 16G), so the swap file is 2/3 of all swap: free swap at 68% means
    # zram is ~97% full (SIGTERM), at 66% ~0.6G went to disk (SIGKILL).
    freeSwapThreshold = 68;
    freeSwapKillThreshold = 66;
    # Matched against /proc/<pid>/comm (15 bytes, extended regex, unanchored);
    # gnome-shell runs as `.gnome-shell-wrapped`. `[.]` instead of `\.`: the
    # arguments pass through a systemd environment variable.
    extraArgs = [
      "--prefer"
      "^(cc1|cc1plus|rustc|ld|ld[.]lld|lld|java|node|dotnet)$"
      "--avoid"
      "^([.]gnome-shell-wr|gnome-shell|Xwayland)$"
    ];
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
