# Claude Code, plus what its plugins need system-wide. User side (plugins,
# skills, MCP servers): home/flodet/_shared/components/claude-code.
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.claude-code ];

  programs.nix-ld.enable = true; # runs the downloaded binaries below

  # Libraries for Chromium builds that npm-installed Playwright downloads
  # (`npx playwright install chromium`, e.g. frontend-slides' PDF export).
  programs.nix-ld.libraries = with pkgs; [
    glib
    nss
    nspr
    atk
    at-spi2-atk
    at-spi2-core
    dbus
    expat
    libgbm
    libxkbcommon
    systemd # libudev
    libx11
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    libxcb
  ];
}
