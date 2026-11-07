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
  ];

  dconf.settings = {
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
