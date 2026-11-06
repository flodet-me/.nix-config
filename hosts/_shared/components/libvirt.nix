# VMs with virt-manager.
{ pkgs, ... }:
let
  key = "/var/lib/libvirt/secrets/secrets-encryption-key";
in
{
  virtualisation.libvirtd.enable = true;
  programs.virt-manager.enable = true;

  # libvirt encrypts its secrets key with systemd's host credential key
  # (/var/lib/systemd/credential.secret). If that key is gone (wiped root,
  # reinstall), libvirtd fails at boot with "Failed to determine local
  # credential key". Move the undecryptable key aside so
  # virt-secret-init-encryption creates a new one.
  systemd.services.libvirt-secret-key-check = {
    description = "Discard libvirt secrets key that can no longer be decrypted";
    wantedBy = [ "libvirtd.service" ];
    before = [
      "virt-secret-init-encryption.service"
      "libvirtd.service"
    ];
    unitConfig.ConditionPathExists = key;
    serviceConfig.Type = "oneshot";
    path = [ pkgs.systemd ];
    script = ''
      if ! systemd-creds decrypt --name=secrets-encryption-key ${key} - >/dev/null; then
        mv ${key} ${key}.undecryptable-$(date +%s)
        echo "moved undecryptable ${key} aside; a new one will be created"
      fi
    '';
  };
}
