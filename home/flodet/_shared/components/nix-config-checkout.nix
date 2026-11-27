# After an install from the stick, ~/.nix-config is a plain copy of the repo
# without git history. On the first login with network this replaces it with
# a checkout of GitHub's current main (HTTPS, public repo, no login needed)
# with scripts/nix-config-checkout (shared with the servers), which carries
# over only what the install added. Then .sops.yaml is regenerated and, with the
# YubiKey plugged in, the secrets are re-encrypted (PIN prompt) and the result
# is committed locally: you only `git push`. Pushing uses SSH with the YubiKey.
{ pkgs, ... }:
let
  repo = "flodet-me/.nix-config";
  inherit ((import ../../../../scripts { inherit pkgs; })) sops-sync nix-config-checkout;
  # Runs in the new checkout, only right after nix-config-checkout made it
  register = pkgs.writeShellScript "nix-config-register" ''
    set -eu
    notify() { notify-send --app-name=nix-config "$1" "$2" || true; echo "$1: $2"; }
    host=$(uname -n)
    if [ -z "$(git status --porcelain)" ]; then
      notify "~/.nix-config is ready" "Checkout of GitHub's main, nothing to commit."
      exit 0
    fi
    if ! sops-sync --no-reencrypt; then
      notify "~/.nix-config: sops-sync failed" "See: journalctl --user -u nix-config-checkout"
      exit 0
    fi
    if gpg --card-status >/dev/null 2>&1 && sops-sync && git add -A && git commit --quiet -m "$host: register sops host key"; then
      notify "~/.nix-config is ready" "Registration of $host committed. Push it: cd ~/.nix-config && git push"
    else
      notify "~/.nix-config needs the YubiKey (or the commit failed)" "Plug it in, then: cd ~/.nix-config && sops-sync && git add -A && git commit -m '$host: register sops host key' && git push"
    fi
  '';
in
{
  systemd.user.services.nix-config-checkout = {
    Unit = {
      Description = "Turn the installer's copy of ~/.nix-config into a git checkout";
      # The signed commit needs the session's display for the PIN prompt
      After = [ "graphical-session.target" ];
      ConditionPathExists = [
        "%h/.nix-config/flake.nix"
        "!%h/.nix-config/.git"
      ];
    };
    Service = {
      Type = "oneshot";
      # waits for the network by retrying
      Restart = "on-failure";
      RestartSec = 60;
      ExecStart = toString (
        pkgs.writeShellScript "nix-config-checkout" ''
          set -eu
          # nix from the system: sops-sync evaluates the flake
          export PATH=${
            pkgs.lib.makeBinPath [
              pkgs.git
              pkgs.coreutils
              pkgs.gnupg
              pkgs.libnotify
              sops-sync
            ]
          }:/run/current-system/sw/bin:$PATH
          # NIX_CONFIG_REPO_URL: only for testing against another repository
          exec ${nix-config-checkout}/bin/nix-config-checkout "$HOME/.nix-config" \
            "''${NIX_CONFIG_REPO_URL:-https://github.com/${repo}.git}" git@github.com:${repo}.git \
            ${register}
        ''
      );
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
