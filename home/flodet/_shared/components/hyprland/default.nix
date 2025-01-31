{
  pkgs,
  ...
}:
{
  imports = [
    ./waybar
  ];

  home.file.".config/hypr/hyprland.conf".source = ./hyprland.conf;
  home.file.".config/hypr/tab.sh".source = ./tab.sh;

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

  # Clipboard manager
  services.cliphist.enable = true;

  # TUI Filemanager
  programs.yazi.enable = true;

  # Audio effects
  services.easyeffects.enable = true;

  # Terminal
  programs.foot.enable = true;

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

    # Utility for clipboard
    wl-clipboard

    networkmanagerapplet
  ];


}
