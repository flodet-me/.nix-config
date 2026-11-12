{
  pkgs,
  ...
}:
{
  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    gnome-tweaks
    gnomeExtensions.appindicator # tray icons: Nextcloud, Discord, ...
    gnomeExtensions.caffeine # keep the screen on (builds, presentations)
    gnomeExtensions.clipboard-history
    gnomeExtensions.alphabetical-app-grid
    gnomeExtensions.dock-from-dash
    gnomeExtensions.space-bar
    gnomeExtensions.color-picker
    gnomeExtensions.headsetcontrol
    gnomeExtensions.mullvad-indicator
    smile # emoji picker, opened with Super+. (like Win+.)
    gnomeExtensions.smile-complementary-extension # lets smile paste the emoji on Wayland
  ];

  dconf.settings = {
    # its default is /usr/local/bin/headsetcontrol, which does not exist on NixOS
    "org/gnome/shell/extensions/HeadsetControl".headsetcontrol-executable =
      "${pkgs.headsetcontrol}/bin/headsetcontrol";
    "org/gnome/shell" = {
      disable-user-extensions = false;

      # `gnome-extensions list` for a list
      enabled-extensions = [
        "appindicatorsupport@rgcjonas.gmail.com"
        "caffeine@patapon.info"
        "clipboard-history@alexsaveau.dev"
        "AlphabeticalAppGrid@stuarthayhurst"
        "dock-from-dash@fthx"
        "space-bar@luchrioh"
        "color-picker@tuberry"
        "HeadsetControl@lauinger-clan.de"
        "mullvadindicator@pobega.github.com"
        "smile-extension@mijorus.it"
        "system-monitor@gnome-shell-extensions.gcampax.github.com"
        "user-theme@gnome-shell-extensions.gcampax.github.com"
      ];

      favorite-apps = [
        "firefox.desktop"
        "code.desktop"
        "org.gnome.Console.desktop"
        "org.gnome.Nautilus.desktop"
      ];
    };

    "org/gnome/desktop/interface" = {
      enable-hot-corners = false;
      clock-format = "24h";
      accent-color = "blue";
      show-battery-percentage = true;
      # Middle click paste
      gtk-enable-primary-paste = true;
    };

    # Windows-like shortcuts. Already GNOME defaults: Super+L lock,
    # Super+arrows tile, Super+Shift+arrows other monitor, Super+1..9 apps, Print.
    "org/gnome/settings-daemon/plugins/media-keys" = {
      home = [ "<Super>e" ];
      control-center = [ "<Super>i" ];
      custom-keybindings = [
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/emoji/"
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/task-manager/"
      ];
    };
    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/emoji" = {
      name = "Emoji picker";
      command = "smile";
      binding = "<Super>period";
    };
    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/task-manager" = {
      name = "Task manager";
      command = "gnome-system-monitor";
      binding = "<Control><Shift>Escape";
    };
    "org/gnome/desktop/wm/keybindings" = {
      show-desktop = [ "<Super>d" ];
      panel-run-dialog = [
        "<Alt>F2"
        "<Super>r"
      ];
      # Alt+Tab cycles windows, not apps
      switch-windows = [ "<Alt>Tab" ];
      switch-windows-backward = [ "<Shift><Alt>Tab" ];
      switch-applications = [ "<Super>Tab" ];
      switch-applications-backward = [ "<Shift><Super>Tab" ];
      switch-to-workspace-left = [
        "<Super><Control>Left"
        "<Super>Page_Up"
        "<Super>KP_Prior"
        "<Super><Alt>Left"
        "<Control><Alt>Left"
      ];
      switch-to-workspace-right = [
        "<Super><Control>Right"
        "<Super>Page_Down"
        "<Super>KP_Next"
        "<Super><Alt>Right"
        "<Control><Alt>Right"
      ];
    };
    "org/gnome/shell/keybindings" = {
      show-screenshot-ui = [
        "Print"
        "<Super><Shift>s"
      ];
      toggle-message-tray = [ "<Super>m" ]; # frees Super+V for the clipboard
    };
    "org/gnome/shell/extensions/clipboard-history".toggle-menu = [ "<Super>v" ];

    "org/gnome/desktop/datetime".automatic-timezone = true;

    "org/gnome/desktop/wm/preferences" = {
      workspace-names = [ "Main" ];
      button-layout = "appmenu:minimize,maximize,close";
    };

    "org/gnome/mutter" = {
      edge-tiling = true;
      dynamic-workspaces = true;
    };

    "org/gnome/desktop/peripherals/touchpad" = {
      tap-to-click = true;
      two-finger-scrolling-enabled = true;
    };

    # Privacy: no location, no crash/usage reports, no external search
    # providers, old trash and temp files are removed.
    "org/gnome/system/location".enabled = false;
    "org/gnome/desktop/privacy" = {
      report-technical-problems = false;
      send-software-usage-stats = false;
      remove-old-trash-files = true;
      remove-old-temp-files = true;
      old-files-age = pkgs.lib.gvariant.mkUint32 30;
    };
    "org/gnome/desktop/search-providers".disable-external = true;
  };
}
