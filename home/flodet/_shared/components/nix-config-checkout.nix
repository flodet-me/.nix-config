# After an install from the stick, ~/.nix-config is a plain copy of the repo
# without git history. On the first login with network this replaces it with
# a checkout of GitHub's current main (HTTPS, public repo, no login needed)
# and carries over only what the install added (listed in .install-keep: the
# host's sops key, the disk if changed). So a stick older than the repo never
# overwrites newer files. Then .sops.yaml is regenerated and, with the
# YubiKey plugged in, the secrets are re-encrypted (PIN prompt) and the result
# is committed locally: you only `git push`. Pushing uses SSH with the YubiKey.
{ pkgs, ... }:
let
  repo = "flodet-me/.nix-config";
  inherit ((import ../../../../scripts { inherit pkgs; })) sops-sync;
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
          notify() { notify-send --app-name=nix-config "$1" "$2" || true; echo "$1: $2"; }
          host=
          installed="$HOME/.nix-config"

          # Clone next to it: a failed attempt (no network yet) changes nothing
          tmp=$(mktemp -d "$HOME/.nix-config-checkout.XXXXXX")
          trap 'rm -rf "$tmp"' EXIT
          # NIX_CONFIG_REPO_URL: only for testing against another repository
          git clone --quiet "''${NIX_CONFIG_REPO_URL:-https://github.com/${repo}.git}" "$tmp/clone"
          git -C "$tmp/clone" remote set-url --push origin git@github.com:${repo}.git

          # Only what the install added
          if [ -f "$installed/.install-keep" ]; then
            while IFS= read -r f; do
              if [ -n "$f" ]; then
                install -D -m 644 "$installed/$f" "$tmp/clone/$f"
              fi
            done <"$installed/.install-keep"
          fi

          old="$HOME/.nix-config.installer"
          rm -rf "$old"
          mv "$installed" "$old"
          mv "$tmp/clone" "$installed"
          rm -rf "$old"
          cd "$installed"

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
        ''
      );
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
