{ config, pkgs, ... }:

{
  # Set monitor configuration, as present in home setup
  home.file.".config/monitors.xml" = {
    source = ./minitors.xml;
    force = true;
  };
}
