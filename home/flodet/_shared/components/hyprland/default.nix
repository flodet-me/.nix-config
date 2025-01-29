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

  programs.hyprlock.enable = true;
  services.hyprpaper.enable = true;

  home.packages = with pkgs; [
    playerctl
    # Color picker
    hyprpicker
    # Allow red filtering
    hyprsunset
  ];


}
