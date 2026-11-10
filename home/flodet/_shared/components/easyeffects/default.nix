{ ... }:

{
  services.easyeffects = {
    enable = true;
    preset = "Perfect_EQ";
  };

  # EasyEffects 8 reads presets from ~/.local/share; from ~/.config it tries to
  # copy them over and fails on read-only copies. force: replaces those copies.
  # Input filter. Source: https://gist.github.com/jtrv/47542c8be6345951802eebcf9dc7da31
  xdg.dataFile."easyeffects/input" = {
    source = ./input;
    recursive = true;
    force = true;
  };

  # Output filter. Source: https://github.com/JackHack96/EasyEffects-Presets
  xdg.dataFile."easyeffects/output" = {
    source = ./output;
    recursive = true;
    force = true;
  };
}
