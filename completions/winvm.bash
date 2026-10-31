# Bash completion for winvm.  Loaded by 'nix develop'; elsewhere add to ~/.bashrc:
#   source /path/to/windows-vm/completions/winvm.bash      (or: source <(winvm completion))
# zsh: autoload -U +X bashcompinit && bashcompinit, then source this file.

# The checkout winvm runs from, to read VM, image, recipe and snapshot names.
_winvm_root() {
    local bin
    bin=$(type -P "${1:-winvm}" 2>/dev/null) || return 1
    bin=$(readlink -f "$bin") && dirname "$bin"
}

_winvm_vms() {
    local d
    for d in "$1"/state/vms/*/; do [[ -d $d ]] && basename "$d"; done
}

_winvm_images() {
    local f
    for f in "$1"/images/*.env; do
        [[ -f $f && $f != *.local.env ]] && basename "$f" .env
    done
}

_winvm_recipes() {
    local d
    for d in "$1"/recipes/*/; do
        d=$(basename "$d")
        [[ -d $1/recipes/$d && $d != _* ]] && echo "$d"
    done
}

_winvm_snapshots() {  # root vm
    local disk=$1/state/vms/$2/disk.qcow2
    [[ -f $disk ]] || return 0
    # -U: readable while the VM runs.  Rows: ID TAG VM-SIZE DATE ...
    qemu-img snapshot -U -l "$disk" 2>/dev/null | awk 'NR > 2 && NF >= 2 { print $2 }'
}

_winvm() {
    local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]}
    local root vm=${WINVM_VM:-default} cmd="" ci=0 i w words=()
    root=$(_winvm_root "${COMP_WORDS[0]}") || root=""

    local commands="fetch build start stop status list images reset snapshot commit destroy
        new recipes apply seal ssh scp rdp wait ssh-config info ps kill service apps events
        ports windows key reboot run crashes debug uitest screenshot netcap proxy trace usb
        completion help"

    # The command is the first word after the global -n NAME / --vm=NAME.
    for ((i = 1; i < COMP_CWORD; i++)); do
        w=${COMP_WORDS[i]}
        case $w in
            -n|--vm) vm=${COMP_WORDS[i+1]:-$vm}; ((i++)) ;;
            --vm=*) vm=${w#--vm=} ;;
            *) cmd=$w ci=$i; break ;;
        esac
    done
    # Words typed after the command (not counting the one being completed).
    ((ci)) && words=("${COMP_WORDS[@]:ci+1:COMP_CWORD-ci-1}")

    _winvm_reply() { COMPREPLY=($(compgen -W "$*" -- "$cur")); }
    _winvm_files() { compopt -o filenames 2>/dev/null; COMPREPLY=($(compgen -f -- "$cur")); }
    _winvm_has_program() {
        local j
        for ((j = 0; j < n; j++)); do
            case ${words[j]} in --timeout|--dir) ((j++)) ;; -*) ;; *) return 0 ;; esac
        done
        return 1
    }

    if [[ -z $cmd ]]; then
        case $prev in
            -n|--vm) _winvm_reply "$(_winvm_vms "$root")"; return ;;
        esac
        if [[ $cur == -* ]]; then _winvm_reply "-n --vm --help"; else _winvm_reply "$commands"; fi
        return
    fi

    # Option values.
    case $prev in
        --image) _winvm_reply "$(_winvm_images "$root")"; return ;;
        --recipe) _winvm_reply "$(_winvm_recipes "$root")"; return ;;
        --dir) compopt -o filenames 2>/dev/null; COMPREPLY=($(compgen -d -- "$cur")); return ;;
        --since) _winvm_reply "30m 1h 2h 6h 1d 7d"; return ;;
        --timeout|--log) return ;;
    esac

    local n=${#words[@]} flags="" args=""
    case $cmd in
        fetch) flags="--refresh" ;;
        build) flags="--image --force --headless --offline --online --no-updates" ;;
        start) flags="--headless --gui --wait --temp --online --offline --image --kd --gdb" ;;
        stop) flags="--force" ;;
        status) flags="--json" ;;
        reset) flags="--image" ;;
        seal|commit) flags="--yes" ;;
        new) flags="--recipe --image --offline" ;;
        apply)
            flags="--seal --offline"
            ((n == 0)) && args=$(_winvm_recipes "$root") ;;
        recipes) ((n == 0)) && args="list new" ;;
        snapshot|snap)
            if ((n == 0)); then args="save load delete list"
            elif ((n == 1)) && [[ ${words[0]} == load || ${words[0]} == delete ]]; then
                args=$(_winvm_snapshots "$root" "$vm")
            fi ;;
        destroy) flags="--all --yes"; args=$(_winvm_vms "$root") ;;
        debug)
            if ((n == 0)); then args="info vs windbg stop kernel"
            elif [[ ${words[0]} == kernel ]] && ((n == 1)); then args="on off"; fi ;;
        uitest) ((n == 0)) && args="info start stop" ;;
        crashes) ((n == 0)) && args="list analyze" ;;
        netcap|proxy) ((n == 0)) && args="start stop" ;;
        trace) flags="--etw"; ((n == 0)) && args="start stop" ;;
        usb)
            if ((n == 0)); then args="list attach detach"
            elif ((n == 1)) && command -v lsusb >/dev/null; then
                args=$(lsusb 2>/dev/null | awk '{ print $6 }')
            fi ;;
        kill) flags="--tree" ;;
        service) ((n == 0)) && args="list show start stop restart enable manual disable" ;;
        apps) flags="--store"; ((n == 0)) && args="uninstall" ;;
        events) flags="--since --errors --all --log" ;;
        windows) flags="--all --children" ;;
        key) args="ctrl-alt-delete alt-f4 alt-tab meta_l meta_l-r meta_l-l ret esc tab f5 f11" ;;
        reboot) flags="--no-wait" ;;
        run)
            # Before the program: options; the program and its arguments: host files.
            if [[ $cur == -* ]] && ! _winvm_has_program; then _winvm_reply "--timeout --no-wait --temp --dir --help"
            else _winvm_files; fi
            return ;;
        scp) _winvm_files; [[ -z $cur ]] && COMPREPLY+=("vm:"); return ;;
        completion) ((n == 0)) && args="bash" ;;
        help) ((n == 0)) && args=$commands ;;
        ssh|rdp|list|images|wait|ssh-config|info|ports|screenshot|ps) ;;
    esac

    if [[ $cur == -* ]]; then _winvm_reply "$flags --help"; else _winvm_reply "$args"; fi
}

complete -F _winvm winvm
