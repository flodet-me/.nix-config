{
  home.file.".config/waybar/config.jsonc".source = ./config.jsonc;

  home.file.".config/waybar/custom_modules/" = {
    source = ./custom_modules;
    recursive = true;
  };

  # Status bar
  programs.waybar = {
    enable = true;
  };
}
