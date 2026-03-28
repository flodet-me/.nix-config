{ inputs, ... }:
{
  imports = [ inputs.impermanence.homeManagerModules.impermanence ];

  home.persistence."/persistence/home/flodet" = {
    allowOther = true;

    directories = [
      # Default folders
      "Projects"
      "Cloud"
      "Downloads"
      "Desktop"

      # Config
      ".nix-config"

      # Shell history & config
      ".local/share/zsh"
      ".zsh"

      # GPG & SSH
      ".gnupg"
      ".ssh"

      # SOPS
      ".config/sops"

      # Password / secrets
      ".local/share/keyrings"

      # GNOME state & extensions
      ".local/share/gnome-shell"
      ".config/dconf"              # all GNOME settings live here
      ".local/share/gvfs-metadata"

      # Fonts
      ".local/share/fonts"

      # Misc
      ".config/blender"
      ".config/chromium"
      ".config/discord"
      ".config/draw.io"
      ".config/gimp"
      ".config/JetBrains"
      ".config/Ledger Live"
      ".config/Ledger Wallet"
      ".config/libvirt"
      ".config/Nextcloud"
      ".config/obsidian"
      ".config/obs-studio"
      ".config/spotify"
      ".config/VSCodium"

      ".local/share/icons"
      ".local/share/JetBrains"
      ".local/share/keyrings"
      ".local/share/krita"
      ".local/share/bemoji"
      ".local/share/applications"
      ".local/share/backgrounds"
      ".local/share/direnv"

      # Gaming
      ".steam"
      ".local/share/Steam"
      { directory = ".local/share/lutris"; }
      { directory = ".local/share/bottles"; }
      ".wine"

      # Zotero
      ".zotero"

      # VS Code
      ".config/Code"
      ".vscode"
      ".vscode-oss"

      # LibreOffice
      ".config/libreoffice"

      # Cameras / cameractrls
      ".config/cameractrls"

      # EasyEffects
      ".config/easyeffects"
      ".local/share/easyeffects"

      # Mullvad
      ".local/share/mullvad-vpn"

      # Firefox
      ".mozilla/firefox"

      # Docker
      ".docker"

      # .NET
      ".dotnet"
      ".nuget"

      # Rust
      ".cargo"
      ".rustup"

      # Sonarlint
      ".sonarlint"

      # NPM
      ".npm"

      # Thumbnails & cache worth keeping
      ".cache/thumbnails"

      # Android Studio
      "Android"
      ".config/Google/"
      ".local/share/Google/AndroidStudio"
      ".android"
      ".gradle"
      ".java"
    ];

    files = [
      ".config/autostart/Nextcloud.desktop"
      ".bash_history"
      ".zsh_history"
      ".config/monitors.xml"
      "mimeapps.list"
      "gnome-initial-setup-done"
    ];
  };
}
