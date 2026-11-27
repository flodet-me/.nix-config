# Bash completion for jail and jail-push (pkgs/jail/README.md). The jail
# package installs it as jail.bash and jail-push.bash, and _jail_zsh for zsh
# (autoload -U +X bashcompinit && bashcompinit, then this file).
# COMPREPLY=($(compgen ...)): zsh's bashcompinit has no mapfile.
# shellcheck disable=SC2207

# the jails' state, a folder per jail
_jail_states() {
    local d
    for d in "$HOME"/.local/share/jails/* "$HOME"/.local/share/jails/.[!.]*; do
        [[ -d $d ]] && echo "$d"
    done
}

_jail_names() {
    local d
    for d in $(_jail_states); do echo "${d##*/}"; done
}

# repositories with a jail: the path each start records, if it still exists
# shortcut: one word per path, so a path with a space does not complete.
_jail_repos() {
    local d r
    for d in $(_jail_states); do
        [[ -f $d/repo ]] && r=$(<"$d/repo") && [[ -d $r ]] && echo "$r"
    done
}

# branches of the mirror of the repository around DIR: the longest recorded
# path at or above it
_jail_branches() {
    local d s r best="" mirror=""
    d=$(cd "${1/#\~/$HOME}" 2>/dev/null && pwd -P) || return 0
    for s in $(_jail_states); do
        [[ -f $s/repo ]] || continue
        r=$(<"$s/repo")
        if [[ $d == "$r" || $d == "$r"/* ]] && ((${#r} > ${#best})); then
            best=$r mirror=$s/mirror.git
        fi
    done
    [[ -n $mirror && -d $mirror ]] || return 0
    git --git-dir="$mirror" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null
}

_jail_dirs() {
    compopt -o filenames 2>/dev/null || true
    COMPREPLY+=($(compgen -d -- "$cur"))
}

# jail push / jail-push: DIR (word $1) is a repository with a jail or any
# folder, then the branches of its mirror
_jail_push_args() {
    if ((COMP_CWORD == $1)); then
        [[ $cur == -* ]] && return
        COMPREPLY=($(compgen -W "$(_jail_repos)" -- "$cur"))
        _jail_dirs
    else
        COMPREPLY=($(compgen -W "$(_jail_branches "${COMP_WORDS[$1]}")" -- "$cur"))
    fi
}

_jail() {
    # zsh (bashcompinit): bash's 0-based arrays, word splitting and globbing
    [[ -z ${ZSH_VERSION:-} ]] || setopt localoptions ksharrays shwordsplit nonomatch
    local cur=${COMP_WORDS[COMP_CWORD]} i
    COMPREPLY=()
    if ((COMP_CWORD == 1)); then
        COMPREPLY=($(compgen -W "config list status stop reset push help --help" -- "$cur"))
        [[ $cur == -* ]] || _jail_dirs
        return
    fi
    case ${COMP_WORDS[1]} in
        config | status) ((COMP_CWORD == 2)) && _jail_dirs ;;
        stop | reset)
            if [[ $cur == -* ]]; then
                COMPREPLY=($(compgen -W "--all $([[ ${COMP_WORDS[1]} == reset ]] && echo --approved --home)" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$(_jail_names)" -- "$cur"))
                _jail_dirs
            fi ;;
        push) _jail_push_args 2 ;;
        list | help) ;;
        *)
            # jail [DIR] -- CMD...: --, then a command, then files
            for ((i = 1; i < COMP_CWORD; i++)); do [[ ${COMP_WORDS[i]} == -- ]] && break; done
            if ((i == COMP_CWORD)); then
                COMPREPLY=($(compgen -W "--" -- "$cur"))
            elif ((COMP_CWORD == i + 1)); then
                COMPREPLY=($(compgen -c -- "$cur"))
            else
                compopt -o filenames 2>/dev/null || true
                COMPREPLY=($(compgen -f -- "$cur"))
            fi ;;
    esac
}

_jail_push() {
    [[ -z ${ZSH_VERSION:-} ]] || setopt localoptions ksharrays shwordsplit nonomatch
    local cur=${COMP_WORDS[COMP_CWORD]}
    COMPREPLY=()
    _jail_push_args 1
}

complete -F _jail jail
complete -F _jail_push jail-push
