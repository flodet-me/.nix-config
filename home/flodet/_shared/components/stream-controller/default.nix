{ config, pkgs, ... }:

{
  # Scripts for usage with stream-controller
  home.file.".config/stream-controller/toggle-audio-device-change.sh" = {
    source = ./scripts/toggle-audio-device-change.sh;
    executable = true;
  };
}
