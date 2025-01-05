{ config, pkgs, ... }:

{
  # QMK default config
  # If using qmk cli file needs to be removed and reinitialized to enable editing
  home.file.".config/qmk/qmk.ini".source = ./qmk.ini;
}
