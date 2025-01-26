{ config, pkgs, ... }:

{
  # Input filter for easyeffects
  # Source: https://gist.github.com/jtrv/47542c8be6345951802eebcf9dc7da31
  home.file.".config/easyeffects/input/" = {
    source = ./input;
    recursive = true;
  };

  # Output filter for easyeffects
  # Source: https://github.com/JackHack96/EasyEffects-Presets
  home.file.".config/easyeffects/output/" = {
    source = ./output;
    recursive = true;
  };
}
