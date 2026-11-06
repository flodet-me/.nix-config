# Opt out of telemetry wherever software offers a switch (all hosts, imported
# by global.nix). Proprietary apps without a switch are covered on the network
# level by moon's DNS blocklists (hosts/moon/dns.nix). See docs/privacy.md.
{ lib, ... }:
let
  optOut = {
    DO_NOT_TRACK = "1"; # generic, honoured by many CLIs (consoledonottrack.com)
    # Claude Code: telemetry, error reporting, feedback, update checks
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    DISABLE_TELEMETRY = "1";
    DISABLE_ERROR_REPORTING = "1";
    # Microsoft
    DOTNET_CLI_TELEMETRY_OPTOUT = "1";
    POWERSHELL_TELEMETRY_OPTOUT = "1";
    AZURE_CORE_COLLECT_TELEMETRY = "0";
    VCPKG_DISABLE_METRICS = "1";
    # JavaScript tooling
    NEXT_TELEMETRY_DISABLED = "1";
    NUXT_TELEMETRY_DISABLED = "1";
    ASTRO_TELEMETRY_DISABLED = "1";
    GATSBY_TELEMETRY_DISABLED = "1";
    STORYBOOK_DISABLE_TELEMETRY = "1";
    TURBO_TELEMETRY_DISABLED = "1";
    NG_CLI_ANALYTICS = "false";
    SCARF_ANALYTICS = "false"; # npm packages using Scarf
    # Others
    HF_HUB_DISABLE_TELEMETRY = "1";
    CHECKPOINT_DISABLE = "1"; # HashiCorp tools
    SAM_CLI_TELEMETRY = "0";
  };
in
{
  environment.sessionVariables = optOut;
  systemd.globalEnvironment = optOut; # services and user units outside a login shell

  # Location lookups send nearby Wi-Fi networks to a location service
  # (GNOME: automatic time zone / night light). Set those manually instead.
  services.geoclue2.enable = lib.mkForce false;
}
