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
    impeccable = "pbakaus/impeccable";
    agricidaniel-claude-obsidian = "AgriciDaniel/claude-obsidian";
    frontend-slides = "zarazhangrui/frontend-slides";
  };

  # Plugins as <plugin>@<marketplace>. `claude-plugins-official` is built in.
  # One plugin per job; docs/claude-code.md says which to use when. Local
  # only: nothing that needs an online service or subscription at runtime.
  plugins = [
    "ponytail@ponytail" # smallest change, review
    "superpowers@claude-plugins-official" # plan -> TDD -> debug -> verify, used by /factory
    "claude-obsidian@agricidaniel-claude-obsidian" # the shared brain: ~/brain, see `brain` below
    "frontend-slides@frontend-slides"
    # Language servers for what ~/Projects is written in; binaries in home.packages.
    "rust-analyzer-lsp@claude-plugins-official"
    "typescript-lsp@claude-plugins-official"
    "csharp-lsp@claude-plugins-official"
  ];

  # Installed but off by default; a project turns one on in its own
  # .claude/settings.json (`enabledPlugins`), project settings win.
  optInPlugins = [
    # UI design + anti-pattern detector (successor of frontend-design); its hooks
    # run on every edit and turn end and download its engine on first use, so only
    # in UI projects.
    "impeccable@impeccable"
  ];

  # Non-sensitive plugin options (what /plugin configure stores).
  pluginConfigs = {
    "ponytail@ponytail".options = {
      ledger = true;
      sendNames = false; # no webhook is set; keep it that way
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

  # Pinned: its skill runs in every project and an unpinned install moved on its
  # own (a new Python rebuilt the venv). Raise it after reading the new SKILL.md;
  # the sync script cuts the "Graphify Cloud" section out of it.
  graphifyVersion = "0.9.120";

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

  # Claude delegates an independent review to Codex; Codex never edits this
  # checkout. Its own CLI login and subscription remain separate from Claude's.
  codexReview = pkgs.writeShellApplication {
    name = "claude-codex-review";
    runtimeInputs = [ pkgs.codex ];
    text = ''
      if [ "$#" -eq 0 ]; then
        echo "Usage: claude-codex-review <review prompt>" >&2
        exit 2
      fi

      # --ask-for-approval is a global flag: `codex exec` rejects it
      exec codex --ask-for-approval never exec --sandbox read-only "$@"
    '';
  };

  # Preserve Codex's local project trust entries while owning stable defaults.
  codexToml = pkgs.writeText "codex-managed-config.toml" (builtins.readFile ./codex/config.toml);
  tomlkitPython = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
  codexConfigMergeScript = pkgs.writeText "merge-codex-config.py" ''
    import os
    import stat
    import sys
    import tempfile
    from pathlib import Path

    import tomlkit

    target = Path(sys.argv[1])
    managed_path = Path(sys.argv[2])
    owned_keys = {
        "model",
        "model_reasoning_effort",
        "approval_policy",
        "sandbox_mode",
        "web_search",
        "allow_login_shell",
    }
    managed_table_keys = {
        "shell_environment_policy": {"ignore_default_excludes"},
        "sandbox_workspace_write": {"network_access"},
        "tui": {"status_line"},
    }

    target.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o600
    current_text = target.read_text() if target.exists() else ""
    current = tomlkit.parse(current_text) if current_text.strip() else tomlkit.document()
    managed = tomlkit.parse(managed_path.read_text())

    for key in owned_keys:
        current.pop(key, None)
    for table_name, keys in managed_table_keys.items():
        table = current.get(table_name)
        if table is not None:
            for key in keys:
                table.pop(key, None)
    for key, value in managed.items():
        if key in managed_table_keys:
            table = current.get(key)
            if table is None:
                table = tomlkit.table()
                current[key] = table
            for option, option_value in value.items():
                table[option] = option_value
        else:
            current[key] = value

    file_descriptor, temporary_name = tempfile.mkstemp(dir=target.parent, prefix=".codex-config-")
    try:
        with os.fdopen(file_descriptor, "w") as temporary_file:
            temporary_file.write(tomlkit.dumps(current))
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, target)
    except BaseException:
        os.unlink(temporary_name)
        raise
  '';
  codexConfigMerge = pkgs.writeShellApplication {
    name = "codex-config-merge";
    runtimeInputs = [ tomlkitPython ];
    text = ''
      python ${codexConfigMergeScript} "$1" "$2"
    '';
  };

  # Cross-project knowledge: one Obsidian vault, separate from the personal
  # notes vault, used by claude-obsidian from every project.
  brain = "${config.home.homeDirectory}/brain";
  settings = lib.importJSON ./settings.json;

  # Trial (docs/claude-code.md, "Token tools"): rtk rewrites Bash commands to a
  # compact form. false: no hook and no instructions; the tools stay installed.
  rtkTrial = true;
  # Claude Code checks its rules against the command a hook returns. rtk 1.2.0
  # misses path-glob and ask rules and grants `allow` when allow rules cover a
  # command; file commands are excluded in rtkConfig. So a command that matches
  # a Bash deny/ask rule (user settings, every .claude/ from the session's
  # directory up) or changes directory or names a git path option stays as it
  # is, and of rtk's answer only updatedInput is passed on: this hook never
  # decides. Anything unexpected (a broken settings file, odd input): it says
  # nothing and Claude Code runs the command unchanged.
  rtkHook = pkgs.writeShellApplication {
    name = "claude-rtk-hook";
    runtimeInputs = [
      pkgs.jq
      pkgs.rtk
    ];
    text = ''
      input=$(cat)
      command=$(jq -er '.tool_input.command | strings' <<<"$input") || exit 0
      dir=$(jq -r '.cwd // "" | strings' <<<"$input") || exit 0
      case $dir in /*) ;; *) dir="" ;; esac
      files=()
      repo=""
      [ -f "$HOME/.claude/settings.json" ] && files+=("$HOME/.claude/settings.json")
      while [ -n "$dir" ]; do
        for f in "$dir/.claude/settings.json" "$dir/.claude/settings.local.json"; do
          [ -f "$f" ] && files+=("$f")
        done
        [ -e "$dir/.git" ] && repo=1
        [ "$dir" = / ] && break
        dir=$(dirname "$dir")
      done
      # One line per Bash deny/ask rule: B + its words up to the first *.
      guards=$(jq -rn '
        inputs
        | if type == "object" then . else error("settings: not an object") end
        | .permissions // {}
        | if type == "object" then . else error("permissions: not an object") end
        | (.deny // []), (.ask // [])
        | if type == "array" then .[] else error("rules: not a list") end
        | if type == "string" then . else error("rule: not a string") end
        | capture("^Bash\\((?<p>.*)\\)$")? | .p
        | sub(":\\*$"; " *") | gsub("\\s+"; " ") | sub("^ "; "")
        | "B" + (if contains("*") then split("*")[0] else . + " " end)
      ' "''${files[@]}") || exit 0
      # shell operators and runs of whitespace separate words alike
      read -ra parts <<<"''${command//[$'\n\t;&|()<>`']/ }"
      words=" ''${parts[*]} "
      # Claude Code resolves paths after cd and in git's path options; the
      # rewrite would hide them from it.
      for word in " cd " " pushd " " popd " " -C" " --no-index" " --git-dir" " --work-tree" " --file"; do
        [[ $words == *"$word"* ]] && exit 0
      done
      # Outside a work tree git diffs plain files (implicit --no-index).
      [ -n "$repo" ] || exit 0
      # Paths outside the work tree (a git diff of them reads plain files);
      # revision ranges like main..HEAD still pass.
      plain=''${command//>\/dev\/null/ }
      plain=''${plain//> \/dev\/null/ }
      plain=''${plain//[\"\']/}
      read -ra parts <<<"''${plain//[$'\n\t;&|()<>`']/ }"
      for word in "''${parts[@]}"; do
        case $word in \~* | /* | \$* | ..* | */..* | *=/* | *=\~* | *=\$*) exit 0 ;; esac
      done
      while IFS= read -r guard; do
        [[ -n $guard && $words == *" ''${guard#B}"* ]] && exit 0
      done <<<"$guards"
      out=$(rtk hook claude <<<"$input" | jq -c '
        select(.hookSpecificOutput.updatedInput?)
        | {hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: .hookSpecificOutput.updatedInput}}') || exit 0
      if [ -n "$out" ]; then printf '%s\n' "$out"; fi
    '';
  };
  rtkHookCommand = lib.getExe rtkHook;
  rtkConfig = (pkgs.formats.toml { }).generate "rtk-config.toml" {
    telemetry.enabled = false;
    retriever.mode = "sqlite"; # recovery: elided output stays recallable (`rtk recall`)
    hooks.suppress_hook_warning = true; # rtk does not recognize the wrapper below as its hook
    # Claude Code 2.1.329's table of commands whose paths it checks against
    # Read/Edit rules (but git, see rtkHook), plus tree and du: their rewrite
    # `rtk <cmd> <path>` would hide the path, and no text check can resolve
    # paths the way Claude Code does (cd, symlinks, `/./`, `\`).
    hooks.exclude_commands = lib.splitString " " (
      "cd ls find mkdir touch rm rmdir mv cp cat head tail sort uniq wc cut paste column tr file stat"
      + " diff awk gawk mawk nawk strings hexdump od base64 nl tac man rev fold expand unexpand fmt comm"
      + " cmp pr numfmt tsort grep egrep fgrep rg sed jq sha256sum sha1sum md5sum tee tree du"
    );
  };

  untestedSettings = pkgs.writeText "claude-managed-settings.json" (
    builtins.toJSON (
      settings
      // {
        env = settings.env // {
          CLAUDE_OBSIDIAN_VAULT = brain; # skills write here from any project
          CLAUDE_OBSIDIAN_SESSION_CONTEXT = "1"; # inject the vault's bounded wiki/hot.md at session start, /clear, compaction
          # Explicit consent is required because ~/brain is outside project roots.
          CLAUDE_OBSIDIAN_SESSION_CONTEXT_VAULT = brain;
        };
        extraKnownMarketplaces = lib.mapAttrs (_: repo: {
          source = {
            source = "github";
            inherit repo;
          };
        }) marketplaces;
        enabledPlugins = lib.genAttrs plugins (_: true) // lib.genAttrs optInPlugins (_: false);
        inherit pluginConfigs;
        statusLine = {
          type = "command";
          command = lib.getExe statusline;
        };
        hooks = {
          Notification = [
            {
              # only when Claude waits for you, not on auth or agent events
              matcher = "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|quota_auto_resume_fired|quota_auto_resume_stale|quota_auto_resume_disabled";
              hooks = [
                {
                  type = "command";
                  command = lib.getExe notify;
                }
              ];
            }
          ];
        }
        // lib.optionalAttrs rtkTrial {
          PreToolUse = [
            {
              matcher = "Bash";
              hooks = [
                {
                  type = "command";
                  command = rtkHookCommand;
                }
              ];
            }
          ];
        };
      }
    )
  );

  # Claude Code checks its permission rules against the command a hook returns,
  # so a rewrite must not turn a denied or asked command into one no rule
  # matches, nor may the hook grant `allow`. managedSettings fails the build
  # unless every Bash deny/ask rule, and every Read-denied path read by the
  # file commands Claude Code checks against Read rules, stays unchanged.
  guardedRules =
    kind:
    map (r: lib.removeSuffix ")" (lib.removePrefix "${kind}(" r)) (
      lib.filter (lib.hasPrefix "${kind}(") (settings.permissions.deny ++ settings.permissions.ask or [ ])
    );
  example = lib.replaceStrings [ "**" "*" ] [ "x" "x" ];
  guardedCommands = map example (guardedRules "Bash");
  # every spelling of a home path Claude Code resolves
  spellings =
    rule:
    if lib.hasPrefix "//" rule then
      [ (lib.removePrefix "/" rule) ]
    else if lib.hasPrefix "~/" rule then
      map (home: home + lib.removePrefix "~" rule) [
        "~"
        "$HOME"
        config.home.homeDirectory
      ]
    else
      [ rule ];
  guardedReads = lib.concatMap (
    path:
    map (cmd: lib.replaceStrings [ "P" ] [ path ] cmd) [
      "cat P"
      "head -5 P"
      "tail P"
      "sed -n 1p P"
      "grep foo P"
      "rg foo P"
      "wc P"
      "diff P x"
      "ls P"
      "find P"
      "stat P"
      "jq . P"
      "git diff --no-index P x"
    ]
  ) (map example (lib.concatMap spellings (guardedRules "Read")));
  managedSettings =
    pkgs.runCommand "claude-managed-settings.json"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.rtk
        ];
      }
      (
        if rtkTrial then
          ''
            export HOME=$TMPDIR/home
            # the sessions below run in a git work tree, but the last ones
            mkdir -p "$HOME/.git" "$HOME/.claude" "$HOME/.config/rtk"
            cp ${untestedSettings} "$HOME/.claude/settings.json" # rtk reads the rules here
            cp ${rtkConfig} "$HOME/.config/rtk/config.toml"
            # the command the hook hands to Claude Code, run like Claude Code
            # runs it: in the session's directory
            cwd=$HOME
            hook() {
              out=$(cd "$cwd" && jq -n --arg c "$1" --arg d "$cwd" \
                '{hook_event_name: "PreToolUse", tool_name: "Bash", cwd: $d, tool_input: {command: $c}}' \
                | ${rtkHookCommand})
              # the hook must never decide: a decision fails like a wrong rewrite
              if jq -se 'any(.[]; .hookSpecificOutput | has("permissionDecision"))' <<<"$out" >/dev/null; then
                echo "a permissionDecision: $out"
              else
                jq -rs --arg c "$1" '.[0].hookSpecificOutput.updatedInput.command // $c' <<<"$out"
              fi
            }
            failed=0
            expect() {
              got=$(hook "$1")
              [ "$got" = "$2" ] || { echo "FAIL: '$1' became '$got', expected '$2'"; failed=1; }
            }
            expect "git status" "rtk git status"
            expect "nix flake check" "nix flake check"
            for c in ${lib.escapeShellArgs (guardedCommands ++ guardedReads)}; do
              # Claude Code's denies also match past these prefixes
              for prefix in "" "FOO=1 " "timeout 30 " "cd /tmp && "; do
                expect "$prefix$c" "$prefix$c"
              done
            done
            # A project that allows what rtk rewrites and asks for one of them,
            # the session in a subdirectory and in its root.
            mkdir -p "$HOME/proj/.claude" "$HOME/proj/sub"
            echo '{"permissions": {"allow": ["Bash(git *)", "Bash(grep *)"], "ask": ["Bash(git log *)"]}}' \
              > "$HOME/proj/.claude/settings.json"
            for cwd in "$HOME/proj" "$HOME/proj/sub"; do
              expect "git status" "rtk git status"
              expect "grep foo ~/.ssh/id_ed25519" "grep foo ~/.ssh/id_ed25519"
              expect "git log -3" "git log -3"
              expect "timeout 30 git log -3" "timeout 30 git log -3"
              expect "git  log -3" "git  log -3"
            done
            # A nearer settings file that is broken or oddly shaped must not
            # drop the guards: the command stays unchanged.
            for bad in '{"permissions": {' '{"permissions": "x"}' '{"permissions": {"deny": "Bash(x)"}}'; do
              rm -rf "$HOME/proj/bad"
              mkdir -p "$HOME/proj/bad/.claude"
              printf '%s' "$bad" > "$HOME/proj/bad/.claude/settings.json"
              cwd=$HOME/proj/bad
              expect "git status" "git status"
              expect "git log -3" "git log -3"
            done
            # Spellings text matching cannot follow: other directories,
            # odd path forms, a link into a denied directory.
            ln -s "$HOME/.ssh" "$HOME/link"
            cwd=$HOME
            for c in \
              "cd ~/.config && cat sops/age/keys.txt" \
              "cd /run && grep x secrets/foo" \
              "pushd /run && wc secrets/foo" \
              "cat ~/.config//sops/age/keys.txt" \
              "cat /run/./secrets/foo" \
              'cat ~/.\ssh/id_ed25519' \
              "cat ~/link/id_ed25519" \
              "grep x ~/link/id_ed25519" \
              "git diff --no-index ~/link/id_ed25519 x" \
              "git -C ~/link log" \
              "git diff ~/.ssh/id_ed25519 /dev/null" \
              "git diff --stat /run/secrets/foo /dev/null" \
              "git diff --word-diff /run/secrets/foo /dev/null" \
              "git diff ~/link/id_ed25519 /dev/null" \
              "git -c core.x=y diff ~/.ssh/id_ed25519 /dev/null" \
              'git diff "$HOME/.ssh/id_ed25519" /dev/null' \
              "git diff ../../.ssh/id_ed25519 /dev/null" \
              "git diff ../x /dev/null" \
              "git diff --output=~/x"; do
              expect "$c" "$c"
            done
            # git outside a work tree diffs plain files (implicit --no-index)
            mkdir -p "$TMPDIR/plain"
            cwd=$TMPDIR/plain
            expect "git diff .ssh/id_ed25519 x" "git diff .ssh/id_ed25519 x"
            expect "git status" "git status"
            # still rewritten in a work tree: revision ranges are not paths
            cwd=$HOME
            expect "git log main..HEAD" "rtk git log main..HEAD"
            expect "git diff A...B" "rtk git diff A...B"
            expect "git status 2>/dev/null" "rtk git status 2>/dev/null"
            expect "git status" "rtk git status"
            [ "$failed" = 0 ]
            cp ${untestedSettings} $out
          ''
        else
          ''
            jq -e '.hooks | has("PreToolUse") | not' ${untestedSettings}
            cp ${untestedSettings} $out
          ''
      );

  # Downloads/installs everything declared above; every step is idempotent.
  # Runs automatically (systemd user service below) and by hand.
  claude-plugins-sync = pkgs.writeShellApplication {
    name = "claude-plugins-sync";
    runtimeInputs = [
      pkgs.claude-code
      pkgs.coreutils
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.uv
      python
    ];
    text = ''
      # One broken step (a renamed plugin, a flaky download) must not stop the
      # rest: failures are collected and reported at the end (non-zero exit).
      failed=()
      try() { "$@" || failed+=("$*"); }

      # ponytail only refreshes its status line script, it creates it only when no
      # statusLine is set (Nix sets one): seed it so the badge shows on a fresh install.
      try mkdir -p "$HOME/.claude"
      [ -e "$HOME/.claude/ponytail-statusline.sh" ] || try touch "$HOME/.claude/ponytail-statusline.sh"

      ${lib.concatMapStrings (repo: ''
        try claude plugin marketplace add ${repo}
      '') (lib.attrValues marketplaces)}
      ${lib.concatMapStrings (p: ''
        try claude plugin install ${p}
      '') (plugins ++ optInPlugins)}
      ${lib.concatMapStrings (p: ''
        claude plugin disable -s user ${p} >/dev/null 2>&1 || true # already off is fine
      '') optInPlugins}
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
      UV_PYTHON_DOWNLOADS=never try uv tool install "''${reinstall[@]}" --python ${lib.getExe python} graphifyy==${graphifyVersion}
      try "$HOME/.local/bin/graphify" install --platform claude
      # Its skill tells Claude to suggest the hosted Graphify Cloud: not here (local first).
      try sed -i '/^## Graphify Cloud (hosted)$/,/^---$/d' "$HOME/.claude/skills/graphify/SKILL.md"
      if grep -q "Graphify Cloud" "$HOME/.claude/skills/graphify/SKILL.md" 2>/dev/null; then
        failed+=("graphify SKILL.md still mentions Graphify Cloud after strip")
      fi

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
    codexReview
    pkgs.codex
    python
    pkgs.nodejs # ponytail hooks, frontend-slides PDF export, npx-based MCP servers
    pkgs.uv # graphify
    pkgs.gh # your CLI, not Claude's: personal.md keeps Claude on local git
    pkgs.rust-analyzer # rust-analyzer-lsp plugin
    pkgs.typescript-language-server # typescript-lsp plugin
    pkgs.csharp-ls # csharp-lsp plugin
    pkgs.nixd # Nix LSP
    # Token tools (docs/claude-code.md, "Token tools")
    pkgs.ccusage
    pkgs.ast-grep
    pkgs.rtk
  ];
  home.sessionPath = [ "$HOME/.local/bin" ]; # uv tool binaries (graphify)

  # Personal instructions for every session. A rules file, not
  # ~/.claude/CLAUDE.md, because graphify writes into that one.
  home.file.".claude/rules/personal.md".source = ./personal.md;
  home.file.".codex/AGENTS.md".source = ./codex/AGENTS.md;
  # rtk's own `rtk init -g` would write RTK.md plus an @RTK.md line instead.
  home.file.".claude/rules/rtk.md" = lib.mkIf rtkTrial { source = ./rtk.md; };
  xdg.configFile."rtk/config.toml".source = rtkConfig;

  # Goal -> merged code: the factory skill and its two agents (docs/claude-code.md, "Factory").
  home.file.".claude/skills/factory/SKILL.md".source = ./skills/factory/SKILL.md;
  home.file.".claude/skills/consult-codex/SKILL.md".source = ./skills/consult-codex/SKILL.md;
  home.file.".claude/agents/implementer.md".source = ./agents/implementer.md;
  home.file.".claude/agents/reviewer.md".source = ./agents/reviewer.md;

  home.activation.claudeCodeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    settings="${config.home.homeDirectory}/.claude/settings.json"
    run mkdir -p "$(dirname "$settings")"
    tmp="$(mktemp)"
    if [ -s "$settings" ]; then current="$(cat "$settings")"; else current='{}'; fi
    # Nix-owned keys win; arrays are replaced as a whole, not merged. Delete
    # all Nix-owned object keys first so entries removed in Nix don't linger.
    if printf '%s' "$current" | ${lib.getExe pkgs.jq} -s '(.[0] | del(.enabledPlugins, .extraKnownMarketplaces, .env, .pluginConfigs, .permissions, .hooks, .modelSettings, .autoMode, .statusLine)) * .[1]' - ${managedSettings} > "$tmp"; then
      run install -m 600 "$tmp" "$settings"
    else
      echo "claude-code: $settings is not valid JSON, left unchanged" >&2
    fi
    rm -f "$tmp"
  '';

  # Nix owns Codex's global defaults; project trust and unrelated local keys
  # stay in the writable config file. Authentication remains Codex-managed.
  home.activation.codexConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${lib.getExe codexConfigMerge} \
      "${config.home.homeDirectory}/.codex/config.toml" \
      "${codexToml}"
  '';

  # Runs at login and again whenever the declared lists change (new unit
  # file -> restarted on switch). Retries every 60 s, gives up after 10 starts
  # in an hour.
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
