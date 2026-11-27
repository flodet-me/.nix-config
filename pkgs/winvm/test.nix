# winvm without a VM, at build time (part of checks.<system>.scripts):
# shellcheck on its bash scripts, then commands that need no VM against a
# temporary WINVM_HOME, with the package itself read-only (a store path).
# Every check runs; the failures are listed at the end.
{
  runCommand,
  bashInteractive,
  python3,
  qemu-utils,
  shellcheck,
  zsh,
  winvm,
}:
runCommand "winvm-test"
  {
    nativeBuildInputs = [
      shellcheck
      winvm
    ];
  }
  ''
    root=${winvm}/share/winvm
    export HOME=$TMPDIR/home WINVM_HOME=$TMPDIR/winvm-home XDG_DATA_HOME=
    mkdir "$HOME"
    failed=()
    check() { # DESCRIPTION COMMAND...
      local d=$1
      shift
      if "$@" >"$TMPDIR/out" 2>&1; then echo "ok    $d"; else
        echo "FAIL  $d"
        sed 's/^/      | /' "$TMPDIR/out" | tail -n 30
        failed+=("$d")
      fi
    }
    has() { # REGEX COMMAND...: the command succeeds and a line of its output matches
      local out
      out=$("''${@:2}" 2>&1) || { echo "$out"; return 1; }
      grep -qE -- "$1" <<<"$out" || { echo "$out"; echo "(no line matches $1)"; return 1; }
    }
    w() { winvm "$@"; }

    check "shellcheck" shellcheck -x -P SCRIPTDIR \
      "$root/.winvm-wrapped" "$root/tests/smoke.sh" "$root/completions/winvm.bash"
    check "the package root is not writable" test ! -w "$root"

    # Read-only commands: they work without WINVM_HOME and do not create it.
    check "help" has '^Usage: winvm' w help
    check "images lists the shipped images" has '^win10 ' w images
    check "list without VMs" has 'no VMs yet' w list
    check "recipes lists the shipped recipes" has '^hidpi ' w recipes
    check "completion prints the bash completion" has 'complete .*_winvm winvm' w completion
    check "status on an empty home" has 'not built' w status
    check "status --json on an empty home" has '"state": "not-built"' w status --json
    check "home prints WINVM_HOME" has "^$WINVM_HOME\$" w home
    check "an unknown command fails" bash -c '! winvm frobnicate'
    check "read-only and unknown commands leave WINVM_HOME alone" test ! -e "$WINVM_HOME"
    check "the default WINVM_HOME is ~/.local/share/winvm" \
      has "^$HOME/.local/share/winvm\$" env -u WINVM_HOME winvm home

    # Without WINVM_HOME: the first line of ~/.config/winvm/home (home-manager on desktop).
    mkdir -p "$HOME/.config/winvm"
    echo "$TMPDIR/from-config" >"$HOME/.config/winvm/home"
    check "the home from ~/.config/winvm/home" \
      has "^$TMPDIR/from-config\$" env -u WINVM_HOME winvm home
    check "WINVM_HOME wins over the config file" has "^$WINVM_HOME\$" w home
    echo "relative/path" >"$HOME/.config/winvm/home"
    check "a relative path in the config file is refused" \
      has 'not an absolute path' bash -c '! env -u WINVM_HOME winvm home'
    rm "$HOME/.config/winvm/home"

    check "home works with an invalid WINVM_VM" has "^$WINVM_HOME\$" env WINVM_VM=Bad winvm home

    # A WINVM_HOME made by hand on btrfs, not a subvolume: winvm says so.
    if [[ $(stat -f -c %T "$TMPDIR") == btrfs ]]; then
      mkdir "$TMPDIR/by-hand"
      check "a hand-made WINVM_HOME on btrfs gets a note" \
        has 'not a btrfs subvolume' env WINVM_HOME="$TMPDIR/by-hand" winvm recipes new x
    else
      echo "skip  hand-made WINVM_HOME note (build dir not on btrfs)"
    fi

    # Writes go to WINVM_HOME.
    check "recipes new writes to WINVM_HOME" w recipes new mine
    check "the new recipe is editable" test -w "$WINVM_HOME/recipes/mine/recipe.env"
    check "recipes lists your own recipes" has '^mine ' w recipes

    # Local configuration comes from WINVM_HOME.
    mkdir -p "$WINVM_HOME/images"
    echo 'IMAGE="win11"' >"$WINVM_HOME/config.local.env"
    echo 'IMAGE_DESC="local override"' >"$WINVM_HOME/images/win10.local.env"
    check "config.local.env from WINVM_HOME" has '^win11 .*\(default\)' w images
    check "images/NAME.local.env from WINVM_HOME" has '^win10 .*local override' w images

    # VMs live in WINVM_HOME/state.
    mkdir -p "$WINVM_HOME/state/vms/foo"
    check "list shows the VMs in WINVM_HOME" has '^foo ' w list

    # Completion: VM names from WINVM_HOME, recipes from both places.
    complete_words() { # WORD...: the completions for the last (empty) word
      ${bashInteractive}/bin/bash -c 'source "$1"; shift; COMP_WORDS=("$@" ""); COMP_CWORD=$#; _winvm; printf "%s\n" "''${COMPREPLY[@]}"' \
        _ "$root/completions/winvm.bash" "$@"
    }
    check "completion: VM names" has '^foo$' complete_words winvm -n
    check "completion: your recipes" has '^mine$' complete_words winvm new x --recipe
    check "completion: shipped recipes" has '^hidpi$' complete_words winvm new x --recipe
    # zsh runs the same function through bashcompinit (bash arrays, word splitting)
    zsh_words() { # WORD...: as complete_words, in zsh
      ${zsh}/bin/zsh -f -c 'autoload -U +X bashcompinit && bashcompinit; source "$1"; shift
        COMP_WORDS=("$@" ""); COMP_CWORD=$#; _winvm; print -l -- "''${COMPREPLY[@]}"' \
        _ "$root/completions/winvm.bash" "$@"
    }
    check "zsh completion: VM names" has '^foo$' zsh_words winvm -n
    check "zsh completion: recipes" has '^hidpi$' zsh_words winvm new x --recipe
    check "zsh completion: your recipes" has '^mine$' zsh_words winvm new x --recipe

    # winvm ssh COMMAND, with ssh and scp stubbed (the unwrapped script: the
    # wrapper puts the real ones first on PATH). Windows 10's OpenSSH strips
    # double quotes from the guest command line: it must have none.
    mkdir -p "$TMPDIR/stubs" "$WINVM_HOME/state/images/win10"
    echo win10 >"$WINVM_HOME/state/vms/foo/image"
    touch "$WINVM_HOME/state/images/win10/base.qcow2" "$WINVM_HOME/state/vms/foo/disk.qcow2"
    cat >"$TMPDIR/stubs/scp" <<EOF
    #!${bashInteractive}/bin/bash
    cp "\''${@: -2:1}" "$TMPDIR/sent.ps1"; echo "\''${@: -1}" >"$TMPDIR/scp-dest"
    EOF
    cat >"$TMPDIR/stubs/ssh" <<EOF
    #!${bashInteractive}/bin/bash
    echo "\''${@: -1}" >"$TMPDIR/ssh-cmd"
    EOF
    chmod +x "$TMPDIR/stubs/"*
    check "ssh COMMAND: runs" env PATH="$TMPDIR/stubs:$PATH" "$root/.winvm-wrapped" -n foo ssh "Write-Host \"a 'b' c\""
    check "ssh COMMAND: the command goes into the copied script as typed" grep -qF "Write-Host \"a 'b' c\"" "$TMPDIR/sent.ps1"
    check "ssh COMMAND: the guest command line has no double quotes" bash -c '! grep -q "\"" "$1"' _ "$TMPDIR/ssh-cmd"
    check "ssh COMMAND: the guest command line runs the copied script" \
      bash -c 'grep -qF -- "-File $(cut -d: -f2- "$1" | tr / \\\\)" "$2"' _ "$TMPDIR/scp-dest" "$TMPDIR/ssh-cmd"

    # start without a PipeWire socket (a jail, an ssh login): no audio device,
    # instead of a QEMU that refuses to start; with one, audio as before.
    # QEMU stubbed: it records its arguments and writes its pidfile.
    cat >"$TMPDIR/stubs/qemu" <<EOF
    #!${bashInteractive}/bin/bash
    printf '%s\n' "\$@" >"$TMPDIR/qemu-args"
    for ((i = 1; i < \$#; i++)); do [[ \''${!i} == -pidfile ]] && j=\$((i + 1)) && echo \$\$ >"\''${!j}"; done
    sleep 2 # alive until start has seen the pidfile
    EOF
    chmod +x "$TMPDIR/stubs/qemu"
    mkdir -p "$TMPDIR/run"
    start_stub() { # the stub's pidfile goes: the next start sees no running VM
      env QEMU="$TMPDIR/stubs/qemu" XDG_RUNTIME_DIR="$TMPDIR/run" winvm -n foo start --headless &&
        rm "$WINVM_HOME/state/vms/foo/qemu.pid"
    }
    check "start without a PipeWire socket: says so" has 'no PipeWire' start_stub
    check "start without a PipeWire socket: no audio device" bash -c '! grep -q audiodev "$1"' _ "$TMPDIR/qemu-args"
    ${python3}/bin/python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$TMPDIR/run/pipewire-0"
    check "start with a PipeWire socket: audio" start_stub
    check "start with a PipeWire socket: the audio device" grep -qx 'pipewire,id=snd0' "$TMPDIR/qemu-args"

    # Base images shared read-only (a jail's, pkgs/jail/README.md): what would
    # write them says so before it changes anything.
    rm "$WINVM_HOME/state/images/win10/base.qcow2"
    ${qemu-utils}/bin/qemu-img create -q -f qcow2 "$WINVM_HOME/state/images/win10/base.qcow2" 16M
    chmod a-w "$WINVM_HOME/state/images/win10/base.qcow2" "$WINVM_HOME/state/images" "$WINVM_HOME/state/images/win10"
    check "build with read-only base images: refused, saying why" has 'read-only' bash -c '! winvm build --headless'
    check "build with read-only base images: the VMs stay" test -f "$WINVM_HOME/state/vms/foo/disk.qcow2"
    check "commit with read-only base images: refused, saying why" has 'read-only' bash -c '! winvm -n foo commit --yes'
    check "destroy --all with read-only base images: refused, saying why" has 'read-only' bash -c '! winvm destroy --all --yes'
    check "destroy --all with read-only base images: the VMs stay" test -f "$WINVM_HOME/state/vms/foo/disk.qcow2"
    check "a VM is still made and deleted" bash -c 'winvm new bar --image win10 && test -d "$WINVM_HOME/state/vms/bar" && winvm destroy bar --yes'
    chmod u+w "$WINVM_HOME/state/images" "$WINVM_HOME/state/images/win10"

    if ((''${#failed[@]})); then
      printf 'winvm-test: %d failed: %s\n' "''${#failed[@]}" "''${failed[*]}" >&2
      exit 1
    fi
    touch $out
  ''
