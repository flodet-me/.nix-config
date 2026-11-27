# codex; inside a jail (pkgs/jail sets JAIL) with the jail profile,
# ~/.codex/jail.config.toml. Codex 0.171 refuses --profile for commands that
# start no session, so those run without it.
{
  codex,
  symlinkJoin,
  writeShellApplication,
}:
let
  wrapper = writeShellApplication {
    name = "codex";
    text = ''
      if [ -n "''${JAIL:-}" ]; then
        # the command: the first argument after codex's global options (codex --help)
        i=1 sub="" own=""
        while [ "$i" -le $# ]; do
          case ''${!i} in
            -p | --profile | -p?* | --profile=*) own=1 ;;&
            -c | --config | --enable | --disable | --remote | --remote-auth-token-env | -i | --image | -m | --model | --local-provider | -p | --profile | -s | --sandbox | -C | --cd | --add-dir | -a | --ask-for-approval) i=$((i + 2)) ;;
            --) break ;; # a prompt follows
            -*) i=$((i + 1)) ;;
            *)
              sub=''${!i}
              break
              ;;
          esac
        done
        next=$((i + 1))
        if [ -z "$own" ]; then
          case $sub in
            debug) [ "''${!next-}" != prompt-input ] || set -- --profile jail "$@" ;;
            login | logout | plugin | app-server | remote-control | completion | update | doctor | apply | a | migrate-rollouts | cloud | exec-server | features | help) ;;
            *) set -- --profile jail "$@" ;;
          esac
        fi
      fi
      exec ${codex}/bin/codex "$@"
    '';
  };
in
# the wrapper's bin/codex wins over codex's (first in paths)
symlinkJoin {
  name = "codex-${codex.version}";
  paths = [
    wrapper
    codex
  ];
  meta.mainProgram = "codex";
}
