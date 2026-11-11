# Server half of home/flodet/_shared/components/nix-config-checkout.nix:
# install-host leaves a plain copy of the repo (no .git) in ~/.nix-config.
# On the first boot with network this replaces it with a read-only checkout
# of GitHub's main (HTTPS, public repo) and carries over what the install
# added (.install-keep: the host's sops key, the disk if changed), which then
# shows up in `git status`. Servers have no GitHub key: changes are made on a
# workstation and deployed from there (docs/cloud.md).
{ config, pkgs, ... }:
let
  repo = "flodet-me/.nix-config";
  user = config.host.user;
  installed = "${config.users.users.${user}.home}/.nix-config";
in
{
  systemd.services.nix-config-checkout = {
    description = "Turn the installer's copy of ~/.nix-config into a git checkout";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.git
      pkgs.coreutils
    ];
    unitConfig = {
      ConditionPathExists = [
        "${installed}/flake.nix"
        "!${installed}/.git"
      ];
      StartLimitIntervalSec = 0; # keep retrying until GitHub is reachable
    };
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Restart = "on-failure";
      RestartSec = 60;
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
    script = ''
      set -eu
      installed=${installed}
      # Clone next to it: a failed attempt (no network yet) changes nothing
      tmp=$(mktemp -d "$installed-checkout.XXXXXX")
      trap 'rm -rf "$tmp"' EXIT
      git clone --quiet https://github.com/${repo}.git "$tmp/clone"
      git -C "$tmp/clone" remote set-url --push origin git@github.com:${repo}.git

      if [ -f "$installed/.install-keep" ]; then
        while IFS= read -r f; do
          if [ -n "$f" ]; then
            install -D -m 644 "$installed/$f" "$tmp/clone/$f"
          fi
        done <"$installed/.install-keep"
      fi

      mv "$installed" "$tmp/installed"
      mv "$tmp/clone" "$installed"
      echo "~/.nix-config is a checkout of main now; added by the install:"
      git -C "$installed" status --short
    '';
  };
}
