{
  pkgs,
  ...
}:
{
  services = {
    pcscd.enable = true;
    udev.packages = [ pkgs.yubikey-personalization ];

    # Plugging in a YubiKey starts the user service `yubikey-learn`
    # (home/flodet/_shared/components/yubikey-gpg.nix), so gpg knows its keys.
    udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="1050", TAG+="systemd", ENV{SYSTEMD_USER_WANTS}+="yubikey-learn.service"
    '';

    # GNOME's SSH agent would otherwise own SSH_AUTH_SOCK in the graphical
    # session, hiding the YubiKey key served by gpg-agent.
    gnome.gcr-ssh-agent.enable = false;
  };
}
