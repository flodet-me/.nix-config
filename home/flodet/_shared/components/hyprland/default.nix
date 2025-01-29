{
  pkgs,
  ...
}:
{
  imports = [
    ./waybar
  ];

  home.file.".config/hypr/hyprland.conf".source = ./hyprland.conf;

  # Application launcher
  programs.fuzzel = {
    enable = true;
  };

  home.packages = with pkgs; [
    playerctl
  ];
}
