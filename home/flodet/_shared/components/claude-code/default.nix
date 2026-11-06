{
  config,
  lib,
  pkgs,
  ...
}:
# Declarative Claude Code plugins (skills, commands, agents, hooks), see
# docs/claude-code.md. ~/.claude/settings.json stays a normal writable file
# (Claude Code writes to it); activation only merges the keys below into it.
let
  # Marketplaces: name -> GitHub repo. The name must match the marketplace's
  # own `name` in its .claude-plugin/marketplace.json.
  marketplaces = {
    ponytail = "DietrichGebert/ponytail";
    addy-agent-skills = "addyosmani/agent-skills";
  };

  # Plugins as <plugin>@<marketplace>. `claude-plugins-official` is built in.
  plugins = [
    "ponytail@ponytail"
    "agent-skills@addy-agent-skills"
    "rust-analyzer-lsp@claude-plugins-official"
  ];

  # Non-sensitive plugin options (what /plugin configure stores).
  pluginConfigs = {
    "ponytail@ponytail".options = {
      ledger = true;
      sendNames = true;
    };
  };

  managedSettings = pkgs.writeText "claude-managed-settings.json" (
    builtins.toJSON {
      extraKnownMarketplaces = lib.mapAttrs (_: repo: {
        source = {
          source = "github";
          inherit repo;
        };
      }) marketplaces;
      enabledPlugins = lib.genAttrs plugins (_: true);
      inherit pluginConfigs;
    }
  );

  # Downloads/installs everything declared above; safe to re-run.
  claude-plugins-sync = pkgs.writeShellApplication {
    name = "claude-plugins-sync";
    text = ''
      ${lib.concatMapStrings (repo: ''
        claude plugin marketplace add ${repo}
      '') (lib.attrValues marketplaces)}
      ${lib.concatMapStrings (p: ''
        claude plugin install ${p}
      '') plugins}
      echo "Done. Restart Claude Code to load new plugins."
    '';
  };
in
{
  home.packages = [ claude-plugins-sync ];

  home.activation.claudeCodeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    settings="${config.home.homeDirectory}/.claude/settings.json"
    tmp="$(mktemp)"
    { [ -s "$settings" ] && cat "$settings" || echo '{}'; } \
      | ${lib.getExe pkgs.jq} -s '.[0] * .[1]' - ${managedSettings} > "$tmp"
    run mkdir -p "$(dirname "$settings")"
    run install -m 600 "$tmp" "$settings"
    rm -f "$tmp"
  '';
}
