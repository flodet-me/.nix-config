# Use pipe wire as the audio server
{ pkgs, ... }:
{
  security.rtkit.enable = true;
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # No global JACK emulation (`jack.enable` is deprecated: it changes
    # LD_LIBRARY_PATH for every program). A JACK-only app is started as
    # `pw-jack <app>` instead.
  };
  environment.systemPackages = [ pkgs.pipewire.jack ]; # provides pw-jack
}
