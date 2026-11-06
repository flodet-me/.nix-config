# Privacy: telemetry

Goal: send as little usage data to vendors as possible, without breaking
things. Three layers:

| Layer | Where | What |
| --- | --- | --- |
| Opt-out variables | `hosts/_shared/components/privacy.nix` (all hosts) | `DO_NOT_TRACK` plus the specific switches of Claude Code, .NET, PowerShell, Azure, vcpkg, Next/Nuxt/Astro/Gatsby/Storybook/Turbo/Angular, Scarf, Hugging Face, HashiCorp, AWS SAM. Set for login sessions and systemd services. |
| App settings | `firefox.nix` (enforced policies + prefs), `vscode.nix`, `claude-code/settings.json` (`env`) | Firefox: telemetry, studies, crash reports, sponsored content, AI features off, locked. VS Code: telemetry, experiments, online lookups, update checks off. Claude Code: telemetry, error reports, non-essential traffic off. |
| Network | `hosts/moon/dns.nix` | Everything using moon as DNS: ads/trackers (StevenBlack) and device/OS telemetry (hagezi "native" lists: Windows/Office, Samsung, LG, Amazon, Apple, Xiaomi, TikTok). Covers what can't be configured: smart TVs, phones, proprietary apps. |

Also: location services (geoclue) are off, so GNOME's automatic time zone and
night light schedule must be set manually.

## Not covered (decide yourself)

- **Proprietary apps** without an off switch in config: Discord, Spotify,
  Steam, JetBrains Rider, Android Studio, Ledger Live. Check their in-app
  privacy settings once (Rider: Settings → Data Sharing). Their trackers are
  partly blocked by moon's lists when you are at home.
- **VS Code itself** is Microsoft's build; VSCodium (`pkgs.vscodium`) is the
  same editor without the Microsoft parts, but some extensions only work in
  VS Code.
- **Kept on purpose:** Firefox Safe Browsing (hashed lookups to Google; protects
  against malware sites), NetworkManager's connectivity check to
  `nmcheck.gnome.org` (GNOME Foundation; needed for hotel/guest Wi-Fi login
  pages), Firefox's captive-portal check.
- **Away from home** moon's DNS doesn't apply. Mullvad's DNS can block trackers
  too: `mullvad dns set default --block-ads --block-trackers`.
