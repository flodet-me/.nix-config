{ config, pkgs, ... }:

{
  # QMK default config
  home.file.".config/qmk/qmk.ini".source = ./qmk.ini;
}
