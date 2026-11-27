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

  jail = pkgs.writeShellApplication {
    name = "jail";
    runtimeInputs = [
      pkgs.bubblewrap
      pkgs.coreutils
      pkgs.git
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

      # I3 replaces this with a pasta network namespace.
      net=(--share-net)

      args=(
        --unshare-all "''${net[@]}" --die-with-parent --new-session --clearenv
        --ro-bind /nix /nix
        --bind /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket
        --ro-bind /etc /etc
        --ro-bind-try /bin /bin
        --ro-bind-try /usr /usr
        --ro-bind-try /lib64 /lib64
        --ro-bind-try /run/current-system /run/current-system
        --ro-bind-try /run/systemd/resolve /run/systemd/resolve
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

      # The environment is built, not inherited: no session bus, agent
      # sockets or tokens. Only plain settings pass through.
      env=(
        --setenv HOME "$HOME" --setenv USER "$user" --setenv LOGNAME "$user"
        --setenv PATH "/etc/profiles/per-user/$user/bin:/run/current-system/sw/bin"
        --setenv SHELL "''${SHELL:-/bin/sh}" --setenv LANG "''${LANG:-C.UTF-8}"
        --setenv XDG_RUNTIME_DIR "$run"
      )
      for v in TERM COLORTERM EDITOR LOCALE_ARCHIVE TERMINFO_DIRS TZDIR; do
        [ -z "''${!v:-}" ] || env+=(--setenv "$v" "''${!v}")
      done

      if [ $# -gt 0 ]; then
        prepare
        exec bwrap "''${args[@]}" "''${env[@]}" -- "$@"
      fi

      # Shared jail: one tmux server inside per repository, every terminal attaches.
      [ -t 0 ] || die "no terminal; use: jail DIR -- CMD..."
      sockdir=$run/jails/$name
      sock=$sockdir/tmux.sock
      install -d -m 0700 "$run/jails" "$sockdir"

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
        prepare
        # The jail's main process keeps the namespace alive while the session lives.
        # shellcheck disable=SC2016 # expanded by the inner shell
        keepalive='"$1" -S "$2" new-session -d -s main && while "$1" -S "$2" has-session -t main 2>/dev/null; do ${pkgs.coreutils}/bin/sleep 2; done'
        systemd-run --user --quiet --collect --expand-environment=no --unit="jail-$name" -- \
          ${bwrap} "''${args[@]}" --bind "$sockdir" "$sockdir" "''${env[@]}" -- \
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
