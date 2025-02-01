{
  pkgs,
  ...
}:
{
  imports = [
    ./waybar
    ../mullvad-vpn
  ];

# Environment
  home.sessionVariables = {
    EDITOR = "nvim";
    BROWSER = "firefox";
    TERMINAL = "foot";
  };

  home.file.".config/hypr/hyprland.conf".source = ./hyprland.conf;
  home.file.".config/hypr/tab.sh".source = ./tab.sh;
  home.file.".local/share/icons/hyprland.png".source = ./hyprland.png;
  home.file.".config/hypr/menu-power.sh".source = ./menu-power.sh;

  # Application launcher
  programs.fuzzel = {
    enable = true;
  };

  fonts.fontconfig.enable = true;

  # Lockscreen tool
  programs.hyprlock.enable = true;

  # Wallpaper utility
  services.hyprpaper.enable = true;

  # Notification daemon
  services.swaync.enable = true;

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

    # UI for network adjustments
    networkmanagerapplet

    # UI for audio devices
    pavucontrol

    # CLI for notification
    libnotify
    cascadia-code

    # Emoji picker
    bemoji
    # Tool to type emoji
    wtype

    # Secret manager
    bitwarden-cli


    material-symbols

  ];


}
