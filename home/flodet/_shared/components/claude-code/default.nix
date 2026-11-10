{
  config,
  lib,
  pkgs,
  ...
}:
# Declarative Claude Code plugins, skills and MCP servers, see
# docs/claude-code.md. ~/.claude/settings.json stays a normal writable file
# (Claude Code writes to it); every activation (install, switch) merges
# ./settings.json and the plugin keys below into it, so those keys are owned
# by Nix: changes made in Claude Code (/model, /permissions) to them are
# reverted on the next switch. Other keys stay Claude's.
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
  # One plugin per job; docs/claude-code.md says which to use when.
  plugins = [
    "ponytail@ponytail" # smallest change, review
    "agent-skills@addy-agent-skills" # spec -> plan -> build -> test -> ship
    "mattpocock-skills@claude-plugins-official" # grilling, domain modelling, module design
    "frontend-design@claude-plugins-official" # UI that doesn't look generated
    "frontend-slides@frontend-slides"
    # Language servers for what ~/Projects is written in; binaries in home.packages.
    "rust-analyzer-lsp@claude-plugins-official"
    "typescript-lsp@claude-plugins-official"
    "csharp-lsp@claude-plugins-official"
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

  # One line under the prompt: model, folder and branch, context used, cost.
  statusline = pkgs.writeShellApplication {
    name = "claude-statusline";
    runtimeInputs = [
      pkgs.jq
      pkgs.git
    ];
    text = ''
      IFS=$'\t' read -r model dir ctx cost < <(jq -r '[
        .model.display_name,
        .workspace.current_dir,
        (.context_window.used_percentage // 0 | floor),
        (.cost.total_cost_usd // 0 | . * 100 | round / 100)
      ] | @tsv')
      branch=$(git -C "$dir" branch --show-current 2>/dev/null || true)
      badge=$(bash "$HOME/.claude/ponytail-statusline.sh" 2>/dev/null || true)
      printf '%s · %s%s · ctx %s%% · $%s %s' \
        "$model" "''${dir##*/}" "''${branch:+ ($branch)}" "$ctx" "$cost" "$badge"
    '';
  };

  # Desktop notification when Claude waits for you (permission, idle input).
  notify = pkgs.writeShellApplication {
    name = "claude-notify";
    runtimeInputs = [
      pkgs.jq
      pkgs.libnotify
    ];
    text = ''
      notify-send -a "Claude Code" "Claude Code" "$(jq -r '.message // "Waiting for you"')"
    '';
  };

  managedSettings = pkgs.writeText "claude-managed-settings.json" (
    builtins.toJSON (
      lib.importJSON ./settings.json
      // {
        extraKnownMarketplaces = lib.mapAttrs (_: repo: {
          source = {
            source = "github";
            inherit repo;
          };
        }) marketplaces;
        enabledPlugins = lib.genAttrs plugins (_: true);
        inherit pluginConfigs;
        statusLine = {
          type = "command";
          command = lib.getExe statusline;
        };
        hooks.Notification = [
          {
            hooks = [
              {
                type = "command";
                command = lib.getExe notify;
              }
            ];
          }
        ];
      }
    )
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
      # One broken step (a renamed plugin, a flaky download) must not stop the
      # rest: failures are collected and reported at the end (non-zero exit).
      failed=()
      try() { "$@" || failed+=("$*"); }

      ${lib.concatMapStrings (repo: ''
        try claude plugin marketplace add ${repo}
      '') (lib.attrValues marketplaces)}
      ${lib.concatMapStrings (p: ''
        try claude plugin install ${p}
      '') plugins}
      ${lib.concatStrings (
        lib.mapAttrsToList (name: server: ''
          claude mcp remove -s user ${name} >/dev/null 2>&1 || true
          try claude mcp add-json -s user ${name} ${lib.escapeShellArg (builtins.toJSON server)}
        '') mcpServers
      )}
      # graphify is a Python CLI that installs its own skill into ~/.claude/skills.
      # --reinstall when the venv's old Python was garbage-collected.
      reinstall=()
      "$HOME/.local/bin/graphify" --help >/dev/null 2>&1 || reinstall=(--reinstall)
      UV_PYTHON_DOWNLOADS=never try uv tool install "''${reinstall[@]}" --python ${lib.getExe python} graphifyy
      try "$HOME/.local/bin/graphify" install --platform claude

      if [ "''${#failed[@]}" -gt 0 ]; then
        echo "These steps FAILED (the rest was done; the service retries):" >&2
        printf '  %s\n' "''${failed[@]}" >&2
        exit 1
      fi
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
    pkgs.perl # agent-skills hooks
    pkgs.gh # mattpocock-skills (issues, PRs)
    pkgs.uv # graphify
    pkgs.rust-analyzer # rust-analyzer-lsp plugin
    pkgs.typescript-language-server # typescript-lsp plugin
    pkgs.csharp-ls # csharp-lsp plugin
  ];
  home.sessionPath = [ "$HOME/.local/bin" ]; # uv tool binaries (graphify)

  # Personal instructions for every session. A rules file, not
  # ~/.claude/CLAUDE.md, because graphify writes into that one.
  home.file.".claude/rules/personal.md".source = ./personal.md;

  home.activation.claudeCodeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    settings="${config.home.homeDirectory}/.claude/settings.json"
    run mkdir -p "$(dirname "$settings")"
    tmp="$(mktemp)"
    if [ -s "$settings" ]; then current="$(cat "$settings")"; else current='{}'; fi
    # Nix-owned keys win; arrays are replaced as a whole, not merged. The plugin
    # lists come only from Nix, so a plugin removed above is disabled too.
    if printf '%s' "$current" | ${lib.getExe pkgs.jq} -s '(.[0] | del(.enabledPlugins, .extraKnownMarketplaces)) * .[1]' - ${managedSettings} > "$tmp"; then
      run install -m 600 "$tmp" "$settings"
    else
      echo "claude-code: $settings is not valid JSON, left unchanged" >&2
    fi
    rm -f "$tmp"
  '';

  # Runs at login and again whenever the declared lists change (new unit
  # file -> restarted on switch). Retries until the network is up.
  systemd.user.services.claude-plugins-sync = {
    Unit = {
      Description = "Install declared Claude Code plugins and skills";
      # a broken plugin name must not retry forever
      StartLimitIntervalSec = 3600;
      StartLimitBurst = 10;
    };
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
