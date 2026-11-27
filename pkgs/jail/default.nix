# `jail` and `jail-push` (user guide: ./README.md; docs/jail.md, design: docs/agent-isolation.md,
# ADR 0001): one bubblewrap jail per git repository, shared by your shell,
# Neovim and the agents; pushes leave through a mirror outside the jail.
# Scripts: ./*.sh, @name@ replaced by store paths below. VM test: ./test.nix
# (checks.x86_64-linux.jail).
{
  lib,
  symlinkJoin,
  writeShellApplication,
  runtimeShell,
  bubblewrap,
  coreutils,
  diffutils,
  findutils,
  git,
  gnugrep,
  iproute2,
  jq,
  passt,
  shellcheck,
  systemd,
  tmux,
  util-linux,
  xdg-dbus-proxy,
}:
let
  # common.sh (for jail, jail-push) + ./<name>.sh, @key@ replaced by subst.key;
  # a placeholder left unreplaced fails evaluation instead of shipping
  script =
    name: runtimeInputs: subst:
    let
      text = builtins.replaceStrings (map (k: "@${k}@") (builtins.attrNames subst)) (map toString (
        builtins.attrValues subst
      )) (prefix name + builtins.readFile ./${name}.sh);
    in
    assert lib.assertMsg (
      builtins.match ".*@[A-Za-z][A-Za-z0-9]*@.*" text == null
    ) "pkgs/jail: unreplaced @placeholder@ in ${name}.sh";
    writeShellApplication { inherit name runtimeInputs text; };
  # common.sh: shared by both commands. Nothing there runs git on the
  # repository: its git files and hooks are written from inside the jail.
  prefix =
    name:
    lib.optionalString (builtins.elem name [
      "jail"
      "jail-push"
    ]) (builtins.readFile ./common.sh);

  # ~/.claude and ~/.codex entries by name (bash extglob alternatives).
  # shared: bound read-write, the login only. state: the jail keeps its own
  # (Claude Code's own list of state in ~/.claude, plus what exists here);
  # transcripts, memory and plans are loaded as instructions, so never shared.
  # Every other entry is bound read-only: config, instructions, code.
  patterns = lib.concatStringsSep "|";
  claudeShared = patterns [ ".credentials.json" ];
  claudeState = patterns [
    "projects"
    "sessions"
    "session-*"
    "todos"
    "tasks"
    "shell-snapshots"
    "statsig"
    "file-history"
    "history.jsonl"
    "ide"
    "logs"
    "*.log"
    "backups"
    "daemon"
    "jobs"
    "teams"
    "usage-data"
    "shares"
    "state"
    "uploads"
    "feedback*"
    "plans"
    "telemetry"
    "metrics"
    "debug"
    "traces"
    "startup-perf"
    "cache"
    "*-cache"
    "*-cache.json"
    "*cache*.json"
    "local"
    "chrome"
    "downloads"
    "scratch"
    "remote*"
    "storage-v2"
    "loop.md"
    "*.lock"
    ".last-cleanup"
    ".device-keys.json"
    ".storage-write"
    ".session_ingress_token"
    ".ponytail-*"
    "ponytail-modes"
  ];
  codexShared = patterns [
    "auth.json"
    "auth.json.lock"
    "auth.lock"
  ];
  codexState = patterns [
    "sessions"
    "log"
    "cache"
    "tmp"
    ".tmp"
    "*.sqlite"
    "*.sqlite-*"
    "*.jsonl"
    "*.lock"
    "*cache*.json"
    "version.json"
    "installation_id"
    "rollout-migrations"
    ".sandbox_migration"
    "thread-writer-locks"
    "tui-*"
  ];

  # Prepares the jail home before each start, in a sandbox that sees only
  # it (at /tmp/home) and the store: a link the jail planted there cannot
  # point a write or read at host files.
  # Args: home-manager's home-files, then mount points (relative) to unlink.
  prepareHome = script "jail-prepare-home" [
    coreutils
    findutils
    jq
  ] { };

  # Opens each bind source of `jail` that jailed code could swap for a link
  # (the repository, .jail's ro/rw paths), checks that the open file is that
  # path, and hands it to bwrap by fd (`--args 5` in bwrap's args takes
  # `--bind-fd`/`--ro-bind-fd`): a link swapped in after jail's check cannot
  # redirect the bind. bwrap closes the fds after mounting. Runs under pasta,
  # which closes inherited fds, right before bwrap.
  # Args: ro|rw PATH ... (ro:DEST|rw:DEST PATH: bound at DEST), --, bwrap and its args.
  jailBinds = script "jail-binds" [ coreutils ] { };

  # Runs `bwrap ARGS...` in a network namespace of its own (pasta, as rootless
  # Podman does) and, with a BUS path, after starting a D-Bus proxy there that
  # lets the jail talk to org.freedesktop.Notifications only. Both last exactly
  # as long as this script. Args: BUS (a socket path, or empty), PORTS (TCP
  # ports forwarded from host 127.0.0.1 to the jail's, comma-separated, or
  # empty), jail-binds' ro|rw[:DEST] PATH pairs, --, bwrap's args.
  jailRun =
    script "jail-run"
      [
        coreutils
        passt
        util-linux
        xdg-dbus-proxy
      ]
      {
        inherit jailBinds bubblewrap;
      };

  jail =
    script "jail"
      [
        bubblewrap
        coreutils
        diffutils
        findutils
        git
        gnugrep
        iproute2
        systemd
        util-linux
      ]
      {
        inherit
          prepareHome
          jailRun
          tmux
          coreutils
          runtimeShell
          claudeShared
          claudeState
          codexShared
          codexState
          ;
        jailPush = jail-push;
      };

  # git-upload-pack / git-receive-pack for jail-push, with only that one
  # repository bound: its config and hooks may run but see nothing else. The
  # directory is opened once and bound by fd, so a symlink swapped in later
  # cannot redirect the bind.
  gitSandbox = script "jail-git-sandbox" [
    bubblewrap
    coreutils
  ] { inherit git; };

  jail-push = script "jail-push" [
    coreutils
    git
  ] { inherit gitSandbox; };
in
symlinkJoin {
  name = "jail";
  paths = [
    jail
    jail-push
  ];
  # the user guide, also inside every jail (/run/current-system/sw/share/doc);
  # bash completion under both names (bash-completion loads it by command
  # name), zsh's the same through its bash emulation
  postBuild = ''
    install -Dm644 ${./README.md} $out/share/doc/jail/README.md
    ${lib.getExe shellcheck} -s bash ${./completions/jail.bash}
    c=$out/share/bash-completion/completions
    install -Dm644 ${./completions/jail.bash} $c/jail.bash
    ln -s jail.bash $c/jail-push.bash
    mkdir -p $out/share/zsh/site-functions
    cat >$out/share/zsh/site-functions/_jail_zsh <<EOF
    #compdef jail jail-push
    autoload -U +X bashcompinit && bashcompinit
    source $c/jail.bash
    if [[ \$service == jail-push ]]; then _bash_complete -F _jail_push; else _bash_complete -F _jail; fi
    EOF
  '';
  meta = {
    description = "One bubblewrap jail per git repository, and jail-push to push from outside it";
    mainProgram = "jail";
    platforms = lib.platforms.linux;
  };
}
