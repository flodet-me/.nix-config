# `jail` and `jail-push` (docs/jail.md, design: docs/agent-isolation.md,
# ADR 0001): one bubblewrap jail per git repository, shared by your shell,
# Neovim and the agents; pushes leave through a mirror outside the jail.
# VM test: ./test.nix (checks.x86_64-linux.jail).
{ lib, pkgs, ... }:
let
  bwrap = "${pkgs.bubblewrap}/bin/bwrap";
  tmux = "${pkgs.tmux}/bin/tmux";

  # Shared by both commands. Nothing here runs git on the repository: its
  # .git/config and hooks are written from inside the jail.
  common = ''
    die() { echo "''${0##*/}: $*" >&2; exit 1; }

    # The nearest directory holding a real .git directory (not a file or
    # symlink), so a worktree or submodule resolves to the repository around it.
    repo_root() {
      local d
      d=$(cd "$1" 2>/dev/null && pwd -P) || die "no such directory: $1"
      while [ ! -d "$d/.git" ] || [ -L "$d/.git" ]; do
        [ "$d" != / ] || die "not inside a git repository: $1"
        d=$(dirname "$d")
      done
      printf '%s\n' "$d"
    }

    # The repository's .git as fd 3, checked to be the real directory: a link
    # swapped in later cannot redirect the reads below.
    open_gitdir() {
      exec 3<"$1/.git" && [ "$(readlink /proc/self/fd/3)" = "$1/.git" ] ||
        { echo "''${0##*/}: $1/.git is not a plain directory" >&2; return 1; }
    }
    # A file in it as data: a regular file, never through a link, no wait on
    # a FIFO, at most 64 KiB.
    read_git_file() {
      local f=/proc/self/fd/3/$1
      [ -f "$f" ] && [ ! -L "$f" ] || { echo "''${0##*/}: .git/$1 is not a regular file" >&2; return 1; }
      dd if="$f" iflag=nofollow,nonblock bs=65536 count=1 status=none
    }
    # remote.origin.url; includes would make host git read any path the jail names
    origin_url() {
      local cfg
      cfg=$(read_git_file config) && printf '%s\n' "$cfg" | git config --no-includes --file - --get remote.origin.url
    }
    # Accepted push URLs: ssh, https, scp-like, or an existing bare repository.
    valid_url() {
      [[ $1 != *[[:cntrl:]]* ]] || return 1
      local host='[A-Za-z0-9][A-Za-z0-9.-]*' user='[A-Za-z0-9_][A-Za-z0-9._~-]*'
      local ssh="^ssh://($user@)?$host(:[0-9]+)?/[^[:space:]]*$"
      local https="^https://$host(:[0-9]+)?/[^[:space:]]*$"
      local scp="^$user@$host:[A-Za-z0-9._~/][^[:space:]]*$"
      [[ $1 =~ $ssh || $1 =~ $https || $1 =~ $scp ]] && return 0
      [[ $1 = /* && $1 != *[[:space:]]* ]] && [ -f "$1/HEAD" ] && [ -d "$1/objects" ] && [ -d "$1/refs" ]
    }
    bad_url="use ssh://, https://, user@host:path or the absolute path of a bare repository"
    # the mirror outside the jail that jail-push pushes from, with its URL
    store_url() {
      { [ -d "$1" ] || git init -q --bare "$1"; } && git --git-dir="$1" config remote.origin.url "$2"
    }

    # basename plus a short hash of the path: ~/.local/share/jails/<name>
    jail_name() {
      local base=''${1##*/}
      printf '%s-%s\n' "''${base//[^A-Za-z0-9._-]/_}" "$(printf %s "$1" | sha256sum | cut -c1-8)"
    }
  '';

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
  prepareHome = pkgs.writeShellApplication {
    name = "jail-prepare-home";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.jq
    ];
    text = ''
      h=/tmp/home
      files=$1
      shift
      fail() { echo "jail: preparing the jail home failed at: $1" >&2; exit 1; }
      # bwrap cannot mount on or below a symlink: drop links the jail made there
      unlink_mounts() {
        local m p c parts
        for m in "$@"; do
          p=$h
          IFS=/ read -ra parts <<<"$m"
          for c in "''${parts[@]}"; do
            p=$p/$c
            [ ! -L "$p" ] || rm -f "$p"
          done
        done
      }
      unlink_mounts "$@" || fail "removing links at mount points"
      # home-manager's dotfiles as links into the store; files the jail made
      # stay, and so do mount points of a running jail (replacing one would
      # detach that mount in the jail)
      find "$h" -type l -lname '/nix/store/*-home-manager-files/*' -delete || fail "removing old home-manager links"
      cp -rs --update=none --no-preserve=mode "$files/." "$h/" || fail "linking home-manager files"
      unlink_mounts "$@" || fail "removing home-manager links at mount points"

      # ~/.claude.json: login and MCP servers from the host, the jail's own
      # project state stays; nothing goes back
      [ -f /tmp/host.json ] || exit 0
      f=$h/.claude.json
      host='{hasCompletedOnboarding, lastOnboardingVersion, lastReleaseNotesSeen, oauthAccount, userID, mcpServers} | with_entries(select(.value != null))'
      if [ -f "$f" ] && jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
        jq --slurpfile h /tmp/host.json ". + (\$h[0] | $host)" "$f" >/tmp/new || fail "merging ~/.claude.json"
      else
        jq "$host" /tmp/host.json >/tmp/new || fail "reading your ~/.claude.json"
      fi
      cp --remove-destination /tmp/new "$f" || fail "writing ~/.claude.json"
    '';
  };

  # Runs `bwrap ARGS...` in a network namespace of its own (pasta, as rootless
  # Podman does) and, with a BUS path, after starting a D-Bus proxy there that
  # lets the jail talk to org.freedesktop.Notifications only. Both last exactly
  # as long as this script. Args: BUS (a socket path, or empty), PORTS (TCP
  # ports forwarded from host 127.0.0.1 to the jail's, comma-separated, or
  # empty), bwrap's args.
  jailRun = pkgs.writeShellApplication {
    name = "jail-run";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.passt
      pkgs.util-linux
      pkgs.xdg-dbus-proxy
    ];
    text = ''
      bus=$1
      tcp=(-t none)
      [ -z "$2" ] || tcp=(--host-lo-to-ns-lo -t "127.0.0.1/$2")
      shift 2
      # the proxy leaves its socket behind when stopped by a signal
      cleanup() { [ -z "$bus" ] || rm -f "$bus"; }
      trap cleanup EXIT
      if [ -n "$bus" ]; then
        rm -f "$bus"
        # The proxy stops when the pipe's read end closes: it is held here only
        # (pasta closes inherited fds), so the proxy ends with this script.
        exec {ready}< <(exec xdg-dbus-proxy --fd=1 "unix:path=''${XDG_RUNTIME_DIR:?}/bus" "$bus" \
          --filter --talk=org.freedesktop.Notifications)
        read -r -N1 -t 10 -u "$ready" _ || { echo "jail: starting the D-Bus proxy failed" >&2; exit 1; }
      fi
      # Only PORTS forwarded into the namespace (host 127.0.0.1 to its
      # 127.0.0.1), nothing out to the host's ports, the host's loopback not
      # mapped to the gateway; DNS goes to pasta's
      # forwarder at 169.254.1.1 (the jail's resolv.conf), which asks the
      # host's nameserver. Inside pasta's user namespace we are root: bwrap
      # maps back to our ids and drops every capability, as it does when
      # started by a normal user. Not exec: the proxy's pipe must stay open.
      # pasta dies with this script, even by SIGKILL (pdeathsig); the outer env
      # resets SIGINT, ignored in a background job (nohup's HUP stays ignored),
      # the inner one every signal for the jailed program (pasta ignores SIGPIPE).
      setpriv --pdeathsig KILL env --default-signal=INT \
        pasta --config-net --quiet "''${tcp[@]}" -u none -T none -U none --no-map-gw --dns-forward 169.254.1.1 \
        -- env --default-signal ${bwrap} --uid "$(id -u)" --gid "$(id -g)" --cap-drop ALL "$@" <&0 &
      pid=$!
      # A signal to this script (kill, systemctl stop) goes on to pasta, whose
      # death ends bwrap (--die-with-parent); then it is raised here again.
      sig=
      for s in TERM INT HUP; do
        # shellcheck disable=SC2064 # $s now, $pid is set
        trap "sig=$s; kill -$s $pid 2>/dev/null || true" "$s"
      done
      rc=0
      wait "$pid" || rc=$?
      while kill -0 "$pid" 2>/dev/null; do rc=0; wait "$pid" || rc=$?; done
      if [ -n "$sig" ]; then
        cleanup
        trap - EXIT "$sig"
        kill -"$sig" $$
      fi
      exit "$rc"
    '';
  };

  jail = pkgs.writeShellApplication {
    name = "jail";
    runtimeInputs = [
      pkgs.bubblewrap
      pkgs.coreutils
      pkgs.diffutils
      pkgs.git
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.systemd
    ];
    text = common + ''
      usage="usage: jail [DIR] [-- CMD...]"
      dir=$PWD
      if [ $# -gt 0 ] && [ "$1" != -- ]; then
        case $1 in -h | --help) echo "$usage"; exit 0 ;; esac
        dir=$1
        shift
      fi
      if [ $# -gt 0 ]; then
        [ "$1" = -- ] && [ $# -gt 1 ] || die "$usage"
        shift
      fi

      root=$(repo_root "$dir")
      cwd=$(cd "$dir" && pwd -P)
      case $HOME in /home/?*) ;; *) die "HOME must be under /home: $HOME" ;; esac
      case "$HOME/" in "$root"/*) die "$root contains your home directory" ;; esac
      run=''${XDG_RUNTIME_DIR:?jail: XDG_RUNTIME_DIR is not set}
      user=$(id -un)
      name=$(jail_name "$root")
      state=$HOME/.local/share/jails/$name
      jhome=$state/home
      if [ ! -e "$state" ]; then
        # First start: no jailed code has run for this repository yet, so its
        # push URL is still yours. Later ones jail-push asks you to confirm.
        if open_gitdir "$root" && url=$(origin_url) && valid_url "$url"; then
          store_url "$state/mirror.git" "$url" || die "cannot store the push URL in $state/mirror.git"
          printf 'jail: jail-push %s pushes to %q\n' "$root" "$url"
        else
          echo "jail: no push URL recorded for $root (none, or refused: $bad_url); jail-push asks on first use" >&2
        fi
        exec 3<&-
      fi
      mkdir -p "$jhome"

      # On every start: dotfiles, mount points, ~/.claude.json (prepareHome).
      prepare() {
        local gen=$HOME/.local/state/home-manager/gcroots/current-home files host=()
        files=$(readlink -f "$gen/home-files") && [ -d "$files" ] ||
          die "no home-manager generation at $gen (home-manager not activated yet?)"
        [ ! -f "$HOME/.claude.json" ] || host=(--ro-bind "$HOME/.claude.json" /tmp/host.json)
        bwrap --unshare-all --die-with-parent --clearenv --ro-bind /nix /nix \
          --proc /proc --dev /dev --tmpfs /tmp "''${host[@]}" --bind "$jhome" /tmp/home \
          -- ${prepareHome}/bin/jail-prepare-home "$files" "''${mounts[@]#"$HOME"/}" ||
          die "could not prepare $jhome; to start over, reset its home (docs/jail.md, Reset)"
      }

      # jail-run's pasta namespace: --share-net keeps it
      args=(
        --unshare-all --share-net --die-with-parent --new-session --clearenv
        --ro-bind /nix /nix
        --bind /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket
        --ro-bind /etc /etc
        --ro-bind-try /bin /bin
        --ro-bind-try /usr /usr
        --ro-bind-try /lib64 /lib64
        --ro-bind-try /run/current-system /run/current-system
        --proc /proc
        --dev /dev
        --dev-bind-try /dev/kvm /dev/kvm
        --tmpfs /tmp
        --perms 0700 --tmpfs "$run"
        --tmpfs /home
        --bind "$jhome" "$HOME"
      )
      # same path inside, only if it exists
      bind() { [ -e "$2" ] && args+=("$1" "$2" "$2") || true; }
      bind --ro-bind "$HOME/brain"
      bind --bind "$HOME/brain/inbox"
      # ~/.claude, ~/.codex: the jail's own directories, so state, temp files
      # and new names stay in the jail; host entries on top (see the patterns).
      host_entries() {
        local e n
        for e in "$HOME/$1"/* "$HOME/$1"/.*; do
          n=''${e##*/}
          [ -e "$e" ] && [ "$n" != . ] && [ "$n" != .. ] || continue
          if [[ $n == @($2) ]]; then args+=(--bind "$e" "$e")
          elif [[ $n != @($3) ]]; then args+=(--ro-bind "$e" "$e")
          else continue; fi
          mounts+=("$e")
        done
      }
      mounts=()
      host_entries .claude '${claudeShared}' '${claudeState}'
      host_entries .codex '${codexShared}' '${codexState}'
      # plugin state, where plugins also install their dependencies: per jail
      if [ -d "$HOME/.claude/plugins/data" ]; then
        mkdir -p "$state/claude-plugin-data"
        args+=(--bind "$state/claude-plugin-data" "$HOME/.claude/plugins/data")
      fi
      bind --ro-bind "$HOME/.local/bin" # graphify
      bind --ro-bind "$HOME/.local/share/uv/tools" # its venv
      args+=(--bind "$root" "$root" --chdir "$cwd")
      # DNS through pasta (jail-run): the host's resolv.conf (it may name
      # 127.0.0.53) with only its search and options lines. Written outside
      # the jail's reach and replaced whole, a running jail keeps its copy.
      if [ -e /etc/resolv.conf ]; then
        if ! { { grep -E '^(search|domain|options)([[:space:]]|$)' /etc/resolv.conf || true; echo "nameserver 169.254.1.1"; } >"$state/resolv.conf.$$" &&
          mv "$state/resolv.conf.$$" "$state/resolv.conf"; }; then
          die "cannot write $state/resolv.conf"
        fi
        args+=(--ro-bind "$state/resolv.conf" "$(readlink -f /etc/resolv.conf)")
      fi

      # Per-repository config, .jail (docs/jail.md). Jailed code can write it,
      # so only the copy you approved on a terminal is applied; it is read as
      # data like .git/config and stored where the jail cannot see it.
      ports=() portspec=
      esc() { printf '%s' "$1" | cat -v; } # control characters and high bytes as text
      # $1 is $2 or below it
      within() { [ "$1" = "$2" ] || [ "$2" = / ] || [[ $1 == "$2"/* ]]; }
      # A path for ro/rw, or why not: absolute (~/ is your home), no symlink
      # on the way, none of what the jail must not get.
      bind_path() {
        local p=$1 real x
        # shellcheck disable=SC2088 # a literal ~ from the file
        case $p in "~") p=$HOME ;; "~/"*) p=$HOME/''${p#"~/"} ;; esac
        [[ $p == /* ]] || { echo "not an absolute path or ~/..."; return 1; }
        while [[ $p == */ && $p != / ]]; do p=''${p%/}; done
        real=$(realpath -e -- "$p" 2>/dev/null) || { echo "does not exist"; return 1; }
        [ "$real" = "$p" ] || { echo "goes through a symlink or is not canonical (it is $(esc "$real"))"; return 1; }
        [ -d "$p" ] || [ -f "$p" ] || { echo "is not a directory or regular file"; return 1; }
        for x in /nix /run /proc /dev /etc /sys; do
          ! within "$p" "$x" || { echo "is in $x"; return 1; }
        done
        [ "$p" != /tmp ] || { echo "is /tmp"; return 1; }
        for x in "$HOME" "$HOME/.local/share/jails" "$root"; do
          ! within "$x" "$p" || { echo "is or contains $x"; return 1; }
        done
        ! within "$p" "$HOME/.local/share/jails" || { echo "is in the jails' state"; return 1; }
        ! within "$p" "$root" || { echo "is in the repository"; return 1; }
        printf '%s\n' "$p"
      }
      # Applies a config's lines to args, mounts and ports; on the first bad
      # line says which and why (stderr) and fails.
      parse() {
        local n=0 line key val p
        while IFS= read -r line || [ -n "$line" ]; do
          n=$((n + 1)) p=""
          [[ ! $line =~ ^[[:space:]]*(#|$) ]] || continue
          read -r key val <<<"$line" || true
          if [[ $val == *[[:cntrl:]]* ]]; then
            p="control characters"
          else
            case $key in
              port)
                if [[ $val =~ ^[1-9][0-9]{3,4}$ ]] && [ "$val" -le 65535 ]; then
                  # pasta refuses a port given twice
                  [[ " ''${ports[*]} " == *" $val "* ]] || ports+=("$val")
                else
                  p="a port is a number from 1024 to 65535"
                fi ;;
              ro | rw)
                if p=$(bind_path "$val"); then
                  if [ "$key" = ro ]; then args+=(--ro-bind "$p" "$p"); else args+=(--bind "$p" "$p"); fi
                  # a link the jail plants in its home at the mount point goes (prepare)
                  [[ $p != "$HOME"/* ]] || mounts+=("$p")
                  p=
                fi ;;
              # features: I4 adds winvm here
              *) p="unknown keyword (port, ro, rw)" ;;
            esac
          fi
          [ -z "$p" ] || { echo "jail: .jail line $n: $(esc "$line"): $p" >&2; return 1; }
        done <<<"$1"
      }
      # The config to apply: the approved copy, or the repository's .jail once
      # you approve it now. Args: shared or one-off (a taken port then is skipped).
      load_config() {
        local approved=$state/jail.approved f=/proc/self/fd/4/.jail conf="" new why="" answer p fwd=()
        [ ! -e "$approved" ] || conf=$(cat "$approved") || die "cannot read $approved"
        exec 4<"$root" && [ "$(readlink /proc/self/fd/4)" = "$root" ] || die "$root is not a plain directory"
        if [ ! -e "$f" ] && [ ! -L "$f" ]; then
          conf= # no .jail: nothing applied
        elif [ -L "$f" ] || [ ! -f "$f" ]; then
          why="it is not a regular file"
        elif [ "$(stat -c %s "$f")" -gt 65536 ]; then
          why="it is larger than 64 KiB"
        elif ! new=$(dd if="$f" iflag=nofollow,nonblock bs=65536 count=1 status=none); then
          why="it cannot be read"
        elif [ "$new" != "$conf" ]; then
          if ! (parse "$new"); then
            why="see the line above"
          elif [ ! -t 0 ] || [ ! -t 2 ]; then
            why="it changed, and there is no terminal to approve it"
          else
            if [ -n "$conf" ]; then
              echo "jail: $root/.jail changed since you approved it:"
              { diff -u --label approved --label .jail <(printf '%s\n' "$conf") <(printf '%s\n' "$new") || true; } | cat -v
            else
              echo "jail: $root/.jail asks for:"
              printf '%s\n' "$new" | cat -v
            fi >&2
            printf 'Type yes to apply it (a running shared jail keeps its config until it restarts): ' >&2
            read -r answer || true
            if [ "$answer" = yes ]; then
              { printf '%s\n' "$new" >"$approved.new" && mv "$approved.new" "$approved"; } || die "cannot store $approved"
              conf=$new
            else
              why="not approved"
            fi
          fi
        fi
        exec 4<&-
        if [ -n "$why" ]; then
          printf 'jail: %s/.jail is not applied (%s); %s. To review it, start jail on a terminal.\n' "$root" "$why" \
            "$([ -n "$conf" ] && echo "using the copy you approved last" || echo "nothing approved yet")" >&2
        fi
        parse "$conf" || die "the approved .jail ($approved) no longer applies: change .jail and start jail on a terminal"
        # host 127.0.0.1:PORT, forwarded by jail-run's pasta
        for p in "''${ports[@]}"; do
          why=$(ss -Htln "sport = :$p") || die "cannot check port $p (ss)"
          if [ -z "$why" ]; then
            fwd+=("$p")
          elif [ "$1" = shared ]; then
            die "port $p: 127.0.0.1:$p is in use on the host; free it and start the jail again"
          else
            echo "jail: port $p: 127.0.0.1:$p is in use on the host (by this repository's shared jail?), not forwarded" >&2
          fi
        done
        portspec=$(IFS=,; echo "''${fwd[*]}")
      }

      # The environment is built, not inherited: no agent sockets or tokens.
      # Only plain settings pass through.
      env=(
        --setenv HOME "$HOME" --setenv USER "$user" --setenv LOGNAME "$user"
        --setenv PATH "/etc/profiles/per-user/$user/bin:/run/current-system/sw/bin"
        --setenv SHELL "''${SHELL:-/bin/sh}" --setenv LANG "''${LANG:-C.UTF-8}"
        --setenv XDG_RUNTIME_DIR "$run"
      )
      for v in TERM COLORTERM EDITOR LOCALE_ARCHIVE TERMINFO_DIRS TZDIR; do
        [ -z "''${!v:-}" ] || env+=(--setenv "$v" "''${!v}")
      done

      # The session bus only through jail-run's proxy, its socket outside the
      # jail's reach: one per shared jail, one per one-off jail (by PID).
      install -d -m 0700 "$run/jails"
      bus=
      bind_bus() {
        [ -S "$run/bus" ] || return 0
        bus=$1
        args+=(--bind "$bus" "$run/bus")
        env+=(--setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$run/bus")
      }

      if [ $# -gt 0 ]; then
        load_config one-off
        prepare
        bind_bus "$run/jails/$name.bus-$$"
        exec ${jailRun}/bin/jail-run "$bus" "$portspec" "''${args[@]}" "''${env[@]}" -- "$@"
      fi

      # Shared jail: one tmux server inside per repository, every terminal attaches.
      [ -t 0 ] || die "no terminal; use: jail DIR -- CMD..."
      sockdir=$run/jails/$name
      sock=$sockdir/tmux.sock
      install -d -m 0700 "$sockdir"

      # Every tmux client runs sandboxed too: the server is jailed code (or a
      # fake one in the writable socket directory) and can make any client
      # exec a command (MSG_SHELL, detach-client -E). No --new-session, so
      # resizing works; TIOCSTI would need it unless the kernel disables it.
      tiocsti=()
      [ "$(cat /proc/sys/dev/tty/legacy_tiocsti 2>/dev/null)" = 0 ] || tiocsti=(--new-session)
      client_env=()
      for v in TERM COLORTERM LANG LOCALE_ARCHIVE TERMINFO_DIRS; do
        [ -z "''${!v:-}" ] || client_env+=(--setenv "$v" "''${!v}")
      done
      client() {
        bwrap --unshare-all --die-with-parent "''${tiocsti[@]}" --clearenv \
          --ro-bind /nix /nix --ro-bind /etc /etc \
          --ro-bind-try /run/current-system /run/current-system \
          --proc /proc --dev /dev --tmpfs /tmp --bind "$sockdir" "$sockdir" \
          "''${client_env[@]}" -- ${tmux} -S "$sock" "$@"
      }
      alive() { client has-session -t main 2>/dev/null; }

      if ! alive; then
        load_config shared
        prepare
        bind_bus "$run/jails/$name.bus"
        # The jail's main process keeps the namespace alive while the session lives.
        # shellcheck disable=SC2016 # expanded by the inner shell
        keepalive='"$1" -S "$2" new-session -d -s main && while "$1" -S "$2" has-session -t main 2>/dev/null; do ${pkgs.coreutils}/bin/sleep 2; done'
        systemd-run --user --quiet --collect --expand-environment=no --unit="jail-$name" -- \
          ${jailRun}/bin/jail-run "$bus" "$portspec" "''${args[@]}" --bind "$sockdir" "$sockdir" "''${env[@]}" -- \
          ${pkgs.runtimeShell} -c "$keepalive" sh ${tmux} "$sock" ||
          echo "jail: jail-$name did not start, maybe it is starting already" >&2
        for _ in $(seq 50); do alive && break; sleep 0.2; done
        alive || die "jail-$name is not running: journalctl --user -u jail-$name"
      fi
      # attach-session, never new-session -A: that would start a server outside the jail
      client attach-session -t main
    '';
  };

  # git-upload-pack / git-receive-pack for jail-push, with only that one
  # repository bound: its config and hooks may run but see nothing else. The
  # directory is opened once and bound by fd, so a symlink swapped in later
  # cannot redirect the bind.
  gitSandbox = pkgs.writeShellApplication {
    name = "jail-git-sandbox";
    runtimeInputs = [
      pkgs.bubblewrap
      pkgs.coreutils
    ];
    text = ''
      [ $# -eq 2 ] || { echo "usage: jail-git-sandbox git-upload-pack|git-receive-pack PATH" >&2; exit 2; }
      case $1 in
        git-upload-pack) bind=--ro-bind-fd ;;
        git-receive-pack) bind=--bind-fd ;;
        *) echo "jail-git-sandbox: unknown command $1" >&2; exit 2 ;;
      esac
      exec 3<"$2"
      [ "$(readlink /proc/self/fd/3)" = "$2" ] || { echo "jail-git-sandbox: $2 is not a plain directory path" >&2; exit 1; }
      proto=()
      [ -z "''${GIT_PROTOCOL:-}" ] || proto=(--setenv GIT_PROTOCOL "$GIT_PROTOCOL")
      exec bwrap --unshare-all --die-with-parent --new-session --clearenv \
        --ro-bind /nix /nix --ro-bind-try /bin /bin --ro-bind-try /usr /usr \
        --proc /proc --dev /dev --tmpfs /tmp "$bind" 3 "$2" \
        --setenv PATH ${pkgs.git}/bin --setenv HOME /tmp --setenv GIT_CONFIG_NOSYSTEM 1 \
        "''${proto[@]}" -- git "''${1#git-}" "$2"
    '';
  };

  jail-push = pkgs.writeShellApplication {
    name = "jail-push";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
    ];
    text = common + ''
      for v in "''${!GIT_@}"; do unset "$v"; done # GIT_DIR and friends would redirect git
      [ $# -gt 0 ] && [ -d "$1" ] || die "usage: jail-push DIR [git push arguments] (DIR: an existing directory in the repository)"
      root=$(repo_root "$1")
      shift
      gitdir=$root/.git
      state=$HOME/.local/share/jails/$(jail_name "$root")
      mirror=$state/mirror.git
      cd /
      g() { git --git-dir="$mirror" "$@"; }


      open_gitdir "$root" || exit 1
      head=$(read_git_file HEAD | head -n 1) || die "cannot read $gitdir/HEAD"
      url=$( [ -d "$mirror" ] && g config --get remote.origin.url || true)
      if [ -z "$url" ]; then
        # Not recorded when the jail first started: jailed code may have set it.
        url=$(origin_url) || die "$root has no readable remote.origin.url"
        printf -v qurl %q "$url"
        valid_url "$url" || die "refusing remote.origin.url $qurl: $bad_url"
        [ -t 0 ] || die "no push URL stored for $root; run jail-push on a terminal to confirm $qurl"
        printf 'jail-push: no push URL stored for %s; jailed code may have set this one:\n  %s\nType yes to push there from now on: ' "$root" "$qurl" >&2
        read -r answer || true
        [ "$answer" = yes ] || die "not confirmed"
        { mkdir -p "$state" && store_url "$mirror" "$url"; } || die "cannot store the push URL in $mirror"
        echo "jail-push: $root pushes to $qurl from now on (stored in $mirror/config)"
      fi

      g fetch --quiet --no-tags --prune --upload-pack="${gitSandbox}/bin/jail-git-sandbox git-upload-pack" \
        "$gitdir" '+refs/heads/*:refs/heads/*' || die "fetching $root into $mirror failed"

      if [ $# -eq 0 ]; then
        case $head in
          "ref: refs/heads/"?*) branch=''${head#ref: refs/heads/} ;;
          *) die "$root has a detached HEAD: name the branch, e.g. jail-push $root main" ;;
        esac
        g check-ref-format --branch "$branch" >/dev/null || die "bad branch name in $gitdir/HEAD: $branch"
        set -- "refs/heads/$branch"
      fi
      rp=()
      case $url in /*) rp=(--receive-pack="${gitSandbox}/bin/jail-git-sandbox git-receive-pack") ;; esac
      g push "''${rp[@]}" origin "$@" || die "push to $url failed"
    '';
  };
in
{
  home.packages = [
    jail
    jail-push
  ];
}
