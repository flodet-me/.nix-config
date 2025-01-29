{
  pkgs,
  ...
}:
{
  home.file.".config/hypr/hyprland.conf".source = ./hyprland.conf;
  home.file.".config/waybar/config.jsonc".source = ./config.jsonc;

  programs.fuzzel = {
    enable = true;
  };

  programs.waybar = {
    enable = true;
  };

  home.packages = with pkgs; [
    playerctl
  ];
}
