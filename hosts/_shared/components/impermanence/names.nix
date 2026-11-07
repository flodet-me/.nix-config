# Names shared by the disk layout (disko.nix), the boot rollback (default.nix)
# and the installer script, so a rename cannot get out of sync.
{
  # LUKS mapper name: /dev/mapper/<name>
  luks = "crypted";
  # Where sops-nix finds the host's age key, on the persistent subvolume
  sopsAgeKey = "/persist/var/lib/sops-nix/key.txt";

  # Second disk (components/data-disk.nix): its LUKS name, the key file that
  # unlocks it after boot (on the encrypted system disk), and the temporary copy
  # install-host makes while formatting
  dataLuks = "data-crypt";
  dataKey = "/persist/etc/data-disk.key";
  dataKeyTmp = "/tmp/data-disk.key";
}
