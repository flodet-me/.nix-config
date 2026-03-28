{ inputs, ... }:
{

  home.persistence."/persistent" = {
    directories = [
      # --- Personal Data ---
      "Projects"
      "Cloud"
      "Downloads"
      "Desktop"
      "Documents"
      "Pictures"
      "Videos"
      ".nix-config"

      # --- Critical Auth & Secrets ---
      { directory = ".gnupg"; mode = "0700"; }
      { directory = ".ssh"; mode = "0700"; }
      { directory = ".local/share/keyrings"; mode = "0700"; }
      ".config/sops"

      # --- Desktop Environment (GNOME) ---
      # dconf is a binary database; it's often better to manage settings via Nix,
      # but if you want manual persistence, this is correct.
      ".config/dconf"
      ".local/share/gnome-shell"
      ".local/share/gvfs-metadata"
      ".local/share/fonts"
      ".local/share/icons"
      ".local/share/backgrounds"
      ".local/share/applications"

      # --- Shell & Core Tools ---
      ".local/share/zsh"
      ".zsh"
      ".local/share/direnv"

      # --- High-Volume / Binary Tools (Consider Symlinks for performance) ---
      # Using symlinks for these prevents double-writes and potential FUSE overhead
      { directory = ".local/share/Steam"; method = "symlink"; }
      { directory = ".local/share/lutris"; method = "symlink"; }
      { directory = ".local/share/bottles"; method = "symlink"; }
      { directory = ".wine"; method = "symlink"; }
      { directory = "Android"; method = "symlink"; }
      { directory = ".gradle"; method = "symlink"; }

      # --- Browsers & Communication ---
      ".mozilla/firefox"
      ".config/chromium"
      ".config/discord"
      ".config/spotify"
      ".config/Nextcloud"
      ".local/share/mullvad-vpn"

      # --- Development & Editors ---
      ".config/JetBrains"
      ".local/share/JetBrains"
      ".config/VSCodium"
      ".config/Code"
      ".vscode"
      ".vscode-oss"
      ".config/obsidian"
      ".docker"
      ".android"

      # Language Runtimes (Note: These grow HUGE. Only persist if you hate re-downloading)
      ".cargo"
      ".rustup"
      ".dotnet"
      ".nuget"
      ".java"
      ".sonarlint"

      # --- Creative & Misc ---
      ".config/blender"
      ".config/gimp"
      ".config/draw.io"
      ".config/obs-studio"
      ".local/share/krita"
      ".zotero"
      ".config/libreoffice"
      ".config/easyeffects"
      ".local/share/easyeffects"
      ".config/cameractrls"
      ".local/share/bemoji"
    ];

    files = [
      ".bash_history"
      ".zsh_history"
      ".config/monitors.xml"
      ".config/gnome-initial-setup-done"
      # Note: mimeapps.list usually lives in .config/
      ".config/mimeapps.list"
      # Better to handle autostart via home-manager options, but if not:
      ".config/autostart/Nextcloud.desktop"
    ];
  };
}
