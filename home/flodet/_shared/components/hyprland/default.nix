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

  # Lockscreen tool
  programs.hyprlock.enable = true;

  # Wallpaper utility
  services.hyprpaper.enable = true;

  # Notification daemon
  services.dunst.enable = true;

  home.packages = with pkgs; [
    playerctl
    # Color picker
    hyprpicker
    # Allow red filtering
    hyprsunset
    # Screenshot
    hyprshot

    # Authentication agent
    hyprpolkitagent

    yazi
  ];


}
