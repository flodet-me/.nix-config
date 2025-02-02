{
  pkgs,
  config,
  inputs,
  ...
}:
{
  imports = [
    inputs.hyprpanel.homeManagerModules.hyprpanel
  ];

  # Environment
  home.sessionVariables = {
    EDITOR = "nvim";
    BROWSER = "firefox";
    TERMINAL = "foot";
    NIXOS_OZONE_WL = "1";
    HOME_LOCATION = "$(cat ${config.sops.secrets.home-location.path})";
    WEATHER_API_KEY = "$(cat ${config.sops.secrets.weather-api-key.path})";
  };

  sops.secrets.home-location.path = "${config.sops.defaultSymlinkPath}/home-location";
  sops.secrets.weather-api-key.path = "${config.sops.defaultSymlinkPath}/weather-api-key";

  home.file.".config/hypr/hyprland.conf".source = ./hyprland.conf;
  home.file.".config/hypr/tab.sh".source = ./tab.sh;
  home.file.".config/hypr/menu-power.sh".source = ./menu-power.sh;
  home.file.".config/hypr/hypridle.conf".source = ./hypridle.conf;

  # Application launcher
  programs.fuzzel = {
    enable = true;
  };

  fonts.fontconfig.enable = true;

  # Lockscreen tool
  programs.hyprlock.enable = true;

  # Wallpaper utility
  services.hyprpaper.enable = true;

  # Idling utility
  services.hypridle.enable = true;

  # Clipboard manager
  services.cliphist.enable = true;

  # TUI Filemanager
  programs.yazi.enable = true;

  # Terminal
  programs.foot.enable = true;

  programs.hyprpanel = {
    enable = true;
    hyprland.enable = true;
    overwrite.enable = true;

    theme = "dracula_split";

    layout = {
      "bar.layouts" = {
        "1" = {
          left = [
            "windowtitle"
            "media"
          ];
          middle = [
            "updates"
            "workspaces"
            "notifications"
          ];
          right = [
            "systray"
            "hyprsunset"
            "volume"
            "bluetooth"
            "network"
            "clock"
            "dashboard"
          ];
        };
        "*" = {
          left = [
            "windowtitle"
          ];
          middle = [
            "workspaces"
          ];
          right = [
          ];
        };
      };
    };

    settings = {
      bar = {
        autoHide = "never";
        battery.label = false;
        bluetooth.label = false;
        clock.format = "%a %b %d  %H:%M";
        clock.showIcon = true;
        clock.showTime = true;
        customModules.hyprsunset.label = false;
        customModules.hyprsunset.offIcon = "󰖙";
        customModules.hyprsunset.onIcon = "󰖚";
        customModules.updates.label = false;
        launcher.icon = "";
        network.label = true;
        network.showWifiInfo = true;
        notifications.hideCountWhenZero = true;
        notifications.show_total = true;
        volume.label = false;
        windowtitle.class_name = true;
        windowtitle.custom_title = true;
        windowtitle.icon = true;
        windowtitle.truncation = true;
        workspaces.applicationIconOncePerWorkspace = true;
        workspaces.monitorSpecific = true;
        workspaces.numbered_active_indicator = "underline";
        workspaces.showAllActive = false;
        workspaces.showApplicationIcons = false;
        workspaces.showWsIcons = false;
        workspaces.show_icons = false;
        workspaces.show_numbered = false;
        workspaces.workspaceMask = false;
      };
      menus = {
        clock = {
          time = {
            military = true;
            hideSeconds = true;
          };
          weather = {
            location = "$HOME_LOCATION";
            unit = "metric";
            key = "$WEATHER_API_KEY";
          };
        };
        dashboard = {
          controls.enabled = true;
          directories.enabled = false;
          shortcuts.enabled = false;
          stats.enable_gpu = true;
          stats.enabled = true;
          powermenu.avatar.image = "${config.home.homeDirectory}/.local/share/icons/logo.ico";
        };
        media.displayTime = false;
        media.displayTimeTooltip = false;
        media.hideAlbum = false;
        volume.raiseMaximumVolume = false;
      };
      notifications = {
        active_monitor = false;
        monitor = 1;
        position = "top";
      };
      theme = {
        bar.transparent = true;
      };
      wallpaper.enable = false;
    };
  };

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
