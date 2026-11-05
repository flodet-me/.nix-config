{
  pkgs,
  ...
}:
{
  services = {
    pcscd.enable = true;
    udev.packages = [ pkgs.yubikey-personalization ];

    # GNOME's SSH agent would otherwise own SSH_AUTH_SOCK in the graphical
    # session, hiding the YubiKey key served by gpg-agent.
    gnome.gcr-ssh-agent.enable = false;
  };
}
