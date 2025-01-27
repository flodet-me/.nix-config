{
  pkgs,
  ...
}:
{
  home.file.".config/hypr/hyprland.conf".source = ./hyprland.conf;

  programs.wofi = {
    enable = true;
  };

  programs.waybar = {
    enable = true;
  };

  home.packages = with pkgs; [
    playerctl
  ];
}
