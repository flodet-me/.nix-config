{
  config,
  lib,
  pkgs,
  ...
}:
# Declarative Claude Code plugins, skills and MCP servers, see
# docs/claude-code.md. ~/.claude/settings.json stays a normal writable file
# (Claude Code writes to it); activation only merges the keys below into it.
# The system half (claude-code itself, nix-ld libs for npm-downloaded
# browsers) is hosts/_shared/components/claude-code.nix.
let
  # Marketplaces: name -> GitHub repo. The name must match the marketplace's
  # own `name` in its .claude-plugin/marketplace.json.
  marketplaces = {
    ponytail = "DietrichGebert/ponytail";
    addy-agent-skills = "addyosmani/agent-skills";
    frontend-slides = "zarazhangrui/frontend-slides";
  };

  # Plugins as <plugin>@<marketplace>. `claude-plugins-official` is built in.
  plugins = [
    "ponytail@ponytail"
    "agent-skills@addy-agent-skills"
    "mattpocock-skills@claude-plugins-official" # grill-me & co.
    "frontend-slides@frontend-slides"
    "rust-analyzer-lsp@claude-plugins-official"
  ];

  # Non-sensitive plugin options (what /plugin configure stores).
  pluginConfigs = {
    "ponytail@ponytail".options = {
      ledger = true;
      sendNames = true;
    };
  };

  # User-scope MCP servers. Playwright from nixpkgs ships its own browsers;
  # the official plugin's `npx @playwright/mcp` downloads ones NixOS can't run.
  mcpServers = {
    playwright = {
      type = "stdio";
      command = lib.getExe pkgs.playwright-mcp;
      args = [ ];
    };
  };

  # Also the interpreter graphify's uv tool venv is built on.
  python = pkgs.python3.withPackages (ps: [ ps.python-pptx ]); # frontend-slides PPTX import

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

  # Downloads/installs everything declared above; every step is idempotent.
  # Runs automatically (systemd user service below) and by hand.
  claude-plugins-sync = pkgs.writeShellApplication {
    name = "claude-plugins-sync";
    runtimeInputs = [
      pkgs.claude-code
      pkgs.git
      pkgs.uv
      python
    ];
    text = ''
      ${lib.concatMapStrings (repo: ''
        claude plugin marketplace add ${repo}
      '') (lib.attrValues marketplaces)}
      ${lib.concatMapStrings (p: ''
        claude plugin install ${p}
      '') plugins}
      ${lib.concatStrings (
        lib.mapAttrsToList (name: server: ''
          claude mcp remove -s user ${name} >/dev/null 2>&1 || true
          claude mcp add-json -s user ${name} ${lib.escapeShellArg (builtins.toJSON server)}
        '') mcpServers
      )}
      # graphify is a Python CLI that installs its own skill into ~/.claude/skills.
      # --reinstall when the venv's old Python was garbage-collected.
      reinstall=()
      "$HOME/.local/bin/graphify" --help >/dev/null 2>&1 || reinstall=(--reinstall)
      UV_PYTHON_DOWNLOADS=never uv tool install "''${reinstall[@]}" --python ${lib.getExe python} graphifyy
      "$HOME/.local/bin/graphify" install --platform claude
      echo "Done. Restart Claude Code to load new plugins."
    '';
  };
in
{
  # Tools the plugins' hooks, skills and scripts call at runtime.
  home.packages = [
    claude-plugins-sync
    python
    pkgs.nodejs # ponytail hooks, frontend-slides PDF export, npx-based MCP servers
    pkgs.jq # agent-skills hooks
    pkgs.perl # agent-skills hooks
    pkgs.gh # mattpocock-skills (issues, PRs)
    pkgs.uv # graphify
  ];
  home.sessionPath = [ "$HOME/.local/bin" ]; # uv tool binaries (graphify)

  home.activation.claudeCodeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    settings="${config.home.homeDirectory}/.claude/settings.json"
    tmp="$(mktemp)"
    { [ -s "$settings" ] && cat "$settings" || echo '{}'; } \
      | ${lib.getExe pkgs.jq} -s '.[0] * .[1]' - ${managedSettings} > "$tmp"
    run mkdir -p "$(dirname "$settings")"
    run install -m 600 "$tmp" "$settings"
    rm -f "$tmp"
  '';

  # Runs at login and again whenever the declared lists change (new unit
  # file -> restarted on switch). Retries until the network is up.
  systemd.user.services.claude-plugins-sync = {
    Unit.Description = "Install declared Claude Code plugins and skills";
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe claude-plugins-sync;
      Restart = "on-failure";
      RestartSec = 60;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
