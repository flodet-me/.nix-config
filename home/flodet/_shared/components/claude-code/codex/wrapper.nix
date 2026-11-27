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
        case ''${1-} in
          debug) [ "''${2-}" != prompt-input ] || set -- --profile jail "$@" ;;
          login | logout | plugin | app-server | remote-control | completion | update | doctor | apply | a | migrate-rollouts | cloud | exec-server | features | help) ;;
          *) set -- --profile jail "$@" ;;
        esac
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
