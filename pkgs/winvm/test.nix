# winvm without a VM, at build time (part of checks.<system>.scripts):
# shellcheck on its bash scripts, then commands that need no VM against a
# temporary WINVM_HOME, with the package itself read-only (a store path).
# Every check runs; the failures are listed at the end.
{
  runCommand,
  bashInteractive,
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
    check "home prints WINVM_HOME" has "^$WINVM_HOME\$" w home
    check "read-only commands leave WINVM_HOME alone" test ! -e "$WINVM_HOME"
    check "the default WINVM_HOME is ~/.local/share/winvm" \
      has "^$HOME/.local/share/winvm\$" env -u WINVM_HOME winvm home

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

    if ((''${#failed[@]})); then
      printf 'winvm-test: %d failed: %s\n' "''${#failed[@]}" "''${failed[*]}" >&2
      exit 1
    fi
    touch $out
  ''
