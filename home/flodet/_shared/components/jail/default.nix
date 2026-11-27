# `jail` and `jail-push` (docs/jail.md, design: docs/agent-isolation.md,
# ADR 0001): one bubblewrap jail per git repository, shared by your shell,
# Neovim and the agents; pushes leave through a mirror outside the jail.
# VM test: ./test.nix (checks.x86_64-linux.jail).
{ pkgs, ... }:
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

    # basename plus a short hash of the path: ~/.local/share/jails/<name>
    jail_name() {
      local base=''${1##*/}
      printf '%s-%s\n' "''${base//[^A-Za-z0-9._-]/_}" "$(printf %s "$1" | sha256sum | cut -c1-8)"
    }
  '';

  jail = pkgs.writeShellApplication {
    name = "jail";
    runtimeInputs = [
      pkgs.bubblewrap
      pkgs.coreutils
      pkgs.findutils
      pkgs.systemd
      pkgs.tmux
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
      mkdir -p "$jhome"

      # Home-manager's dotfiles as links into the store, refreshed on every
      # start; files the jail made itself stay.
      mirror_dotfiles() {
        local gen=$HOME/.local/state/home-manager/gcroots/current-home files
        files=$(readlink -f "$gen/home-files") && [ -d "$files" ] ||
          die "no home-manager generation at $gen (home-manager not activated yet?)"
        find "$jhome" -type l -lname '/nix/store/*-home-manager-files/*' -delete
        cp -rsf --no-preserve=mode "$files/." "$jhome/"
      }

      # Code every jail would run: read-only. Create them so a jail cannot
      # plant one where none exists yet.
      if [ -d "$HOME/.claude" ]; then
        mkdir -p "$HOME/.claude/rules" "$HOME/.claude/skills" "$HOME/.claude/agents"
        [ -e "$HOME/.claude/settings.json" ] || echo '{}' >"$HOME/.claude/settings.json"
      fi

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
      for c in .cache/nix .cache/nuget .cache/npm .cargo/registry; do bind --bind "$HOME/$c"; done
      bind --bind "$HOME/.claude"
      for p in settings.json rules skills agents; do bind --ro-bind "$HOME/.claude/$p"; done
      bind --bind "$HOME/.claude.json"
      bind --bind "$HOME/.codex"
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
        mirror_dotfiles
        exec bwrap "''${args[@]}" "''${env[@]}" -- "$@"
      fi

      # Shared jail: one tmux server inside per repository, every terminal attaches.
      [ -t 0 ] || die "no terminal; use: jail DIR -- CMD..."
      sockdir=$run/jails/$name
      sock=$sockdir/tmux.sock
      install -d -m 0700 "$run/jails" "$sockdir"
      alive() { tmux -S "$sock" has-session -t main 2>/dev/null; }
      if ! alive; then
        mirror_dotfiles
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

      # The client runs sandboxed too: the server is jailed code and can make a
      # client exec a command (detach-client -E), or be swapped for a fake one.
      # No --new-session so resizing works; TIOCSTI needs it unless disabled.
      tiocsti=()
      [ "$(cat /proc/sys/dev/tty/legacy_tiocsti 2>/dev/null)" = 0 ] || tiocsti=(--new-session)
      client_env=()
      for v in TERM COLORTERM LANG LOCALE_ARCHIVE TERMINFO_DIRS; do
        [ -z "''${!v:-}" ] || client_env+=(--setenv "$v" "''${!v}")
      done
      exec bwrap --unshare-all --die-with-parent "''${tiocsti[@]}" --clearenv \
        --ro-bind /nix /nix --ro-bind /etc /etc \
        --ro-bind-try /run/current-system /run/current-system \
        --proc /proc --dev /dev --tmpfs /tmp --bind "$sockdir" "$sockdir" \
        "''${client_env[@]}" -- ${tmux} -S "$sock" attach-session -t main
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
      dir=$PWD
      if [ $# -gt 0 ] && [ -d "$1" ]; then
        dir=$1
        shift
      fi
      root=$(repo_root "$dir")
      gitdir=$root/.git
      state=$HOME/.local/share/jails/$(jail_name "$root")
      mirror=$state/mirror.git
      cd /
      g() { git --git-dir="$mirror" "$@"; }

      # Accepted push URLs: ssh, https, scp-like, or an existing bare repository.
      valid_url() {
        local host='[A-Za-z0-9][A-Za-z0-9.-]*' user='[A-Za-z0-9_][A-Za-z0-9._~-]*'
        local ssh="^ssh://($user@)?$host(:[0-9]+)?/[^[:space:]]*$"
        local https="^https://$host(:[0-9]+)?/[^[:space:]]*$"
        local scp="^$user@$host:[A-Za-z0-9._~/][^[:space:]]*$"
        [[ $1 =~ $ssh || $1 =~ $https || $1 =~ $scp ]] && return 0
        [[ $1 = /* && $1 != *[[:space:]]* ]] && [ -f "$1/HEAD" ] && [ -d "$1/objects" ] && [ -d "$1/refs" ]
      }

      [ -d "$mirror" ] || { mkdir -p "$state" && git init -q --bare "$mirror"; } || die "cannot create $mirror"
      url=$(g config --get remote.origin.url || true)
      if [ -z "$url" ]; then
        # read as data: --file follows no includes
        url=$(git config --file "$gitdir/config" --get remote.origin.url) || die "$root has no remote.origin.url"
        valid_url "$url" || die "refusing remote.origin.url '$url': use ssh://, https://, user@host:path or the absolute path of a bare repository"
        g config remote.origin.url "$url"
        echo "jail-push: $root pushes to $url from now on (stored in $mirror/config)"
      fi

      g fetch --quiet --no-tags --upload-pack="${gitSandbox}/bin/jail-git-sandbox git-upload-pack" \
        "$gitdir" '+refs/heads/*:refs/heads/*' || die "fetching $root into $mirror failed"

      if [ $# -eq 0 ]; then
        head=$(head -c 256 "$gitdir/HEAD" | head -n 1)
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
