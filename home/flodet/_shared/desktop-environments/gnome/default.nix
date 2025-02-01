{
  pkgs,
  ...
}:
{
  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    # Gnome
    gnome-tweaks
    gnomeExtensions.headsetcontrol
    gnomeExtensions.clipboard-history
    gnomeExtensions.alphabetical-app-grid
    gnomeExtensions.mullvad-indicator
    gnomeExtensions.dock-from-dash
    gnomeExtensions.space-bar
    gnomeExtensions.emoji-copy
    gnomeExtensions.color-picker
  ];

  dconf.settings = {

    # ...
    "org/gnome/shell" = {
      disable-user-extensions = false;

      # `gnome-extensions list` for a list

      enabled-extensions = [
        "AlphabeticalAppGrid@stuarthayhurst"
        "clipboard-history@alexsaveau.dev"
        "dock-from-dash@fthx"
        "mullvadindicator@pobega.github.com"
        "HeadsetControl@lauinger-clan.de"
        "emoji-copy@felipeftn"
        "system-monitor@gnome-shell-extensions.gcampax.github.com"
        "user-theme@gnome-shell-extensions.gcampax.github.com"
        "space-bar@luchrioh"
        "color-picker@tuberry"
      ];

      favorite-apps = [
        "firefox.desktop"
        "org.gnome.Console.desktop"
        "org.gnome.Nautilus.desktop"
      ];
    };

    "org/gnome/desktop/interface" = {
      # color-scheme = "prefer-dark";
      enable-hot-corners = false;
      clock-format = "24h";
      accent-color = "blue";

      # Set middle click paste
      gtk-enable-primary-paste = true;
    };

    "org/gnome/desktop/datetime" = {
      automatic-timezone = true;
    };

    "org/gnome/desktop/wm/preferences" = {
      workspace-names = [ "Main" ];
      button-layout = "appmenu:minimize,maximize,close";
    };
  };
}
