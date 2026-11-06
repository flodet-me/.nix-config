# Firmware updates (BIOS/UEFI, SSD, Thunderbolt, docks, YubiKey...) from LVFS:
#   fwupdmgr refresh && fwupdmgr get-updates && fwupdmgr update
# GNOME Software isn't used here, so updates are applied by hand.
{
  services.fwupd.enable = true;
}
