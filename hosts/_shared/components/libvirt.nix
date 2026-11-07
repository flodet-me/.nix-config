# VMs with virt-manager.
{ pkgs, ... }:
let
  key = "/var/lib/libvirt/secrets/secrets-encryption-key";
  hostKey = "/var/lib/systemd/credential.secret";
in
{
  virtualisation.libvirtd.enable = true;
  programs.virt-manager.enable = true;

  # libvirt encrypts its secrets key with systemd's host credential key
  # (/var/lib/systemd/credential.secret). If that host key is gone (wiped root, reinstall) while
  # libvirt's key survived, libvirtd fails at boot with "Failed to determine
  # local credential key". Move the orphaned key aside so
  # virt-secret-init-encryption creates a new one. Only acts when the host key
  # is really missing, so a transient decrypt error never orphans the secrets.
  systemd.services.libvirt-secret-key-check = {
    description = "Discard libvirt secrets key whose host credential key is gone";
    wantedBy = [ "libvirtd.service" ];
    before = [
      "virt-secret-init-encryption.service"
      "libvirtd.service"
    ];
    unitConfig = {
      ConditionPathExists = [
        key
        "!${hostKey}"
      ];
      RequiresMountsFor = [
        "/var/lib/libvirt"
        "/var/lib/systemd"
      ];
    };
    serviceConfig.Type = "oneshot";
    path = [
      pkgs.coreutils
      pkgs.systemd
    ];
    script = ''
      if ! systemd-creds decrypt --name=secrets-encryption-key "${key}" - >/dev/null 2>&1; then
        mv "${key}" "${key}.undecryptable-$(date +%s)"
        echo "moved undecryptable ${key} aside; a new one will be created"
      fi
    '';
  };
}
